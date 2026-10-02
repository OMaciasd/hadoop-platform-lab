#!/usr/bin/env python3
"""validate.py — cadena de validación de conectividad del hadoop-platform-lab.

Cada comprobación recorre la cadena:

    componente -> dependencia -> conectividad -> servicio -> registro -> fallo

y registra un estado. Los fallos se localizan con exactitud, se marcan las
comprobaciones bloqueadas por ese fallo y la ejecución CONTINÚA con el resto.

Las comprobaciones de un componente concreto (p. ej. hdfs.datanode2) FALLAN si
ese componente cae; las agregadas (hdfs.datanodes.live, yarn.nodes) siguen
ejecutándose y degradan a DEGRADED para mostrar la capacidad real (1/2 nodos).

Estados:
    PASS            correcto
    FAIL            incorrecto (o bloqueado por un FAIL anterior)
    DEGRADED        funciona pero incompleto/subóptimo
    NOT_CONFIGURED  componente no habilitado a propósito en el laboratorio

Límites: una iteración por defecto; --loop N itera N veces con tope absoluto
(MAX_LOOP) y --interval S con mínimo (MIN_INTERVAL). Nunca corre infinitamente
sin que lo pidas.

Uso:
    ./scripts/validate/validate.py
    ./scripts/validate/validate.py --quick
    ./scripts/validate/validate.py --loop 5 --interval 30
    ./scripts/validate/validate.py --only hdfs.write_read --only yarn.nodes
    ./scripts/validate/validate.py --list
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

# ------------------------------------------------------------------ rutas/constantes
LAB_ROOT = Path(__file__).resolve().parents[2]
COMPOSE_FILE = LAB_ROOT / "compose.yaml"
PROJECT = "hadoop-platform-lab"
DATA = LAB_ROOT / "data"
REPORTS = DATA / "reports"
METRICS = DATA / "metrics"
LOGS = DATA / "logs"

MAX_LOOP = 1000
MIN_INTERVAL = 1.0
ITERATION_GUARD = 900.0  # segundos máximos por iteración

PASS, FAIL, DEGRADED, NOT_CONFIGURED = "PASS", "FAIL", "DEGRADED", "NOT_CONFIGURED"
STATES = (PASS, FAIL, DEGRADED, NOT_CONFIGURED)

COLORS = {PASS: "\033[32m", FAIL: "\033[31m", DEGRADED: "\033[33m", NOT_CONFIGURED: "\033[34m"}
RESET = "\033[0m"
BOLD = "\033[1m"


# ------------------------------------------------------------------ utilidades
def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def color(state: str, enabled: bool) -> str:
    if not enabled:
        return state
    return f"{COLORS[state]}{state}{RESET}"


def http_get(url: str, timeout: float) -> tuple[int, str]:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "hadoop-lab-validate/1"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            # hasta 256 KiB: el exportador publica ~15 KiB de métricas
            return resp.status, resp.read(262144).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, ""
    except Exception:
        return 0, ""


def tcp_open(host: str, port: int, timeout: float) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def shell(cmd: list[str], timeout: float) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr)
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except FileNotFoundError as e:
        return 127, str(e)


def compose_exec(command: str, timeout: float) -> tuple[int, str]:
    """Ejecuta un comando dentro del contenedor cliente (si existe)."""
    cmd = ["docker", "compose", "-f", str(COMPOSE_FILE), "--project-name", PROJECT,
           "exec", "-T", "client", "bash", "-lc", command]
    return shell(cmd, timeout)


def docker_inspect(name: str) -> dict | None:
    rc, out = shell(["docker", "inspect", name], 10)
    if rc != 0:
        return None
    try:
        return json.loads(out)[0]
    except Exception:
        return None


def container_state(name: str) -> str:
    info = docker_inspect(name)
    if not info:
        return "absent"
    if info.get("State", {}).get("Health"):
        return info["State"]["Health"]["Status"]
    return info.get("State", {}).get("Status", "unknown")


# ------------------------------------------------------------------ catálogo
@dataclass
class Check:
    id: str
    name: str
    group: str
    deps: list[str]
    func: Callable[[], tuple[str, str]]
    timeout: float = 10.0
    heavy: bool = False
    result: tuple[str, str] = field(default=(NOT_CONFIGURED, "no ejecutado"))
    duration_ms: int = 0
    blocked_by: str | None = None


CHECKS: list[Check] = []


def check(id_: str, name: str, group: str, deps: list[str], timeout: float = 10.0,
          heavy: bool = False):
    def deco(fn: Callable[[], tuple[str, str]]):
        CHECKS.append(Check(id=id_, name=name, group=group, deps=deps, func=fn,
                            timeout=timeout, heavy=heavy))
        return fn
    return deco


# ------------------------------------------------------------------ 1. base
@check("docker.daemon", "Demonio Docker", "base", [])
def c_docker():
    rc, out = shell(["docker", "info"], 15)
    if rc == 0:
        return PASS, "docker responde"
    return FAIL, f"docker info rc={rc}: {out.strip()[:120]}"


@check("lab.network", "Red hadoop_lab", "base", ["docker.daemon"])
def c_network():
    rc, out = shell(["docker", "network", "inspect", "hadoop_lab"], 10)
    if rc != 0:
        return FAIL, "la red hadoop_lab no existe (./scripts/lab/up.sh)"
    try:
        subnet = json.loads(out)[0]["IPAM"]["Config"][0]["Subnet"]
    except Exception:
        subnet = "?"
    if subnet != "172.28.0.0/16":
        return DEGRADED, f"subnet inesperada: {subnet}"
    return PASS, f"red propia {subnet}"


@check("lab.containers", "Contenedores del stack", "base", ["lab.network"])
def c_containers():
    rc, out = shell(["docker", "ps", "--format", "{{.Names}}"], 10)
    running = set(out.split())
    required = {"hl-namenode", "hl-datanode1", "hl-datanode2", "hl-resourcemanager",
                "hl-nodemanager1", "hl-nodemanager2", "hl-client", "hl-metrics"}
    missing = sorted(required - running)
    if not missing:
        return PASS, f"{len(required)}/{len(required)} contenedores en ejecución"
    if len(missing) < len(required):
        return DEGRADED, f"faltan: {', '.join(missing)}"
    return FAIL, f"ningún contenedor del lab ({', '.join(sorted(missing))[:80]})"


def _load_lab_ports() -> tuple[int, ...]:
    """Lista única de puertos: la misma que usan common.sh, up.sh e inventory."""
    common = Path(__file__).resolve().parents[1] / "lib" / "common.sh"
    try:
        match = re.search(r"^LAB_PORTS=\(([^)]*)\)", common.read_text(), re.M)
        return tuple(int(x) for x in match.group(1).split())
    except (OSError, AttributeError, ValueError):
        return (8020, 8042, 8043, 8088, 9864, 9865, 9870, 9871)


LAB_PORTS = _load_lab_ports()


@check("lab.port_conflicts", "Sin conflictos de puertos", "base", ["lab.containers"])
def c_port_conflicts():
    rc, out = shell(["docker", "ps", "--format", "{{.Names}}|{{.Ports}}"], 5)
    publishers: dict[str, list[str]] = {}
    if rc == 0:
        for line in out.splitlines():
            name, _, ports = line.partition("|")
            for mapping in ports.split(","):
                mapping = mapping.strip()
                if "->" not in mapping:
                    continue
                host_port = mapping.split("->")[0].split(":")[-1]
                publishers.setdefault(host_port, []).append(name)
    third_party, unpublished = [], []
    for port in LAB_PORTS:
        pubs = publishers.get(str(port), [])
        if any(n.startswith("hl-") for n in pubs):
            continue  # publicado por este laboratorio
        if tcp_open("127.0.0.1", port, 2):
            third_party.append(f"{port} en manos de {pubs or 'un proceso externo'}")
        else:
            unpublished.append(port)
    if third_party:
        return FAIL, "puertos tomados por terceros: " + "; ".join(third_party)
    if unpublished:
        return DEGRADED, f"sin publicar {unpublished} (¿contenedor caído?)"
    return PASS, "/".join(str(p) for p in LAB_PORTS) + " publicados por hl-*"


# ------------------------------------------------------------------ 2. HDFS
@check("hdfs.namenode.container", "NameNode (contenedor)", "hdfs", ["lab.containers"])
def c_nn_container():
    st = container_state("hl-namenode")
    if st == "healthy":
        return PASS, "hl-namenode healthy"
    if st in ("starting", "unhealthy"):
        return DEGRADED, f"hl-namenode: {st}"
    return FAIL, f"hl-namenode: {st}"


@check("hdfs.namenode.http", "NameNode HTTP/JMX", "hdfs", ["hdfs.namenode.container"])
def c_nn_http():
    code, body = http_get("http://localhost:9870/jmx", 8)
    if code == 200 and "NameNode" in body:
        return PASS, "HTTP 200 en :9870/jmx"
    if code == 0:
        return FAIL, "sin respuesta en :9870"
    return DEGRADED, f"HTTP {code} en :9870"


@check("hdfs.namenode.rpc", "NameNode RPC", "hdfs", ["hdfs.namenode.http"])
def c_nn_rpc():
    return (PASS, "TCP :8020 abierto") if tcp_open("127.0.0.1", 8020, 5) \
        else (FAIL, "TCP :8020 cerrado")


@check("hdfs.safemode", "Safe mode", "hdfs", ["hdfs.namenode.rpc"], timeout=40)
def c_safemode():
    rc, out = compose_exec("hdfs dfsadmin -safemode get", 30)
    if rc != 0:
        return FAIL, f"dfsadmin rc={rc}: {out.strip()[:100]}"
    low = out.lower()
    if "off" in low:
        return PASS, "Safe mode OFF"
    if "on" in low:
        return DEGRADED, f"{out.strip()[:80]} (¿formación o datos pendientes?)"
    return DEGRADED, out.strip()[:100]


@check("hdfs.datanode1", "DataNode 1", "hdfs", ["hdfs.namenode.http"])
def c_dn1():
    st = container_state("hl-datanode1")
    code, _ = http_get("http://localhost:9864/jmx", 5)
    if st == "healthy" and code == 200:
        return PASS, "healthy + JMX :9864"
    if st in ("running", "starting") or code == 200:
        return DEGRADED, f"estado={st} http={code}"
    return FAIL, f"estado={st} http={code}"


@check("hdfs.datanode2", "DataNode 2", "hdfs", ["hdfs.namenode.http"])
def c_dn2():
    st = container_state("hl-datanode2")
    code, _ = http_get("http://localhost:9865/jmx", 5)
    if st == "healthy" and code == 200:
        return PASS, "healthy + JMX :9865"
    if st in ("running", "starting") or code == 200:
        return DEGRADED, f"estado={st} http={code}"
    return FAIL, f"estado={st} http={code}"


@check("hdfs.datanodes.live", "DataNodes registrados", "hdfs",
       ["hdfs.safemode"], timeout=45)
def c_live_dns():
    rc, out = compose_exec("hdfs dfsadmin -report", 40)
    if rc != 0:
        return FAIL, f"dfsadmin -report rc={rc}"
    live = 0
    for line in out.splitlines():
        if line.strip().startswith("Live datanodes"):
            try:
                live = int(line.split("(")[1].split(")")[0])
            except Exception:
                pass
    if live >= 2:
        return PASS, f"{live}/2 DataNodes vivos"
    if live == 1:
        return DEGRADED, "1/2 DataNodes (réplica incompleta)"
    return FAIL, "0/2 DataNodes"


@check("hdfs.write_read", "Escritura/lectura HDFS", "hdfs", ["hdfs.datanodes.live"],
       timeout=180)
def c_roundtrip():
    script = (
        "set -e; d=/lab/validate; hdfs dfs -mkdir -p $d; "
        "printf 'validate-%s' \"$(date -u +%s)\" > /tmp/.v; "
        "hdfs dfs -put -f /tmp/.v $d/f; "
        "hdfs dfs -cat $d/f | grep -q validate-; "
        "hdfs dfs -rm -f $d/f >/dev/null"
    )
    rc, out = compose_exec(script, 170)
    if rc == 0:
        return PASS, "put/cat/rm sobre HDFS correcto"
    return FAIL, f"rc={rc}: {out.strip()[:140]}"


@check("hdfs.capacity", "Capacidad HDFS", "hdfs", ["hdfs.datanodes.live"], timeout=45)
def c_capacity():
    rc, out = compose_exec("hdfs dfsadmin -report", 40)
    if rc != 0:
        return FAIL, "sin informe de capacidad"
    pct, total, used = None, "", ""
    for line in out.splitlines():
        if "Configured Capacity" in line:
            total = line.split(":")[-1].strip()
        if "DFS Used%" in line:
            try:
                pct = float(line.split(":")[-1].strip().rstrip("%"))
            except ValueError:
                pass
        if "DFS Used:" in line:
            used = line.split(":")[-1].strip()
    if pct is None:
        return DEGRADED, "capacidad ilegible"
    if pct >= 90:
        return DEGRADED, f"uso {pct}% de {total}"
    return PASS, f"uso {pct}% ({used} de {total})"


@check("hdfs.persistence", "Persistencia NameNode", "hdfs", ["hdfs.namenode.container"])
def c_persistence():
    version = DATA / "namenode" / "current" / "VERSION"
    if version.exists():
        return PASS, f"fsimage en {version.relative_to(LAB_ROOT)}"
    if container_state("hl-namenode") == "absent":
        return FAIL, "sin contenedor ni fsimage"
    return FAIL, f"no se encontró {version}"


# ------------------------------------------------------------------ 3. YARN
@check("yarn.resourcemanager.container", "ResourceManager (contenedor)", "yarn",
       ["lab.containers"])
def c_rm_container():
    st = container_state("hl-resourcemanager")
    return (PASS, "hl-resourcemanager healthy") if st == "healthy" else \
           ((DEGRADED, f"estado={st}") if st != "absent" else (FAIL, "contenedor ausente"))


@check("yarn.resourcemanager.rest", "YARN REST", "yarn",
       ["yarn.resourcemanager.container"], timeout=15)
def c_rm_rest():
    code, body = http_get("http://localhost:8088/ws/v1/cluster/info", 8)
    if code == 200 and "clusterInfo" in body:
        return PASS, "HTTP 200 /ws/v1/cluster/info"
    return (FAIL, "sin respuesta en :8088") if code == 0 else (DEGRADED, f"HTTP {code}")


@check("yarn.resourcemanager.state", "Estado del clúster YARN", "yarn",
       ["yarn.resourcemanager.rest"])
def c_rm_state():
    code, body = http_get("http://localhost:8088/ws/v1/cluster/info", 8)
    state, ha = "", ""
    try:
        info = json.loads(body)["clusterInfo"]
        state, ha = info.get("state", ""), info.get("haState", "")
    except Exception:
        pass
    # sin HA el RM reporta state=STARTED; con HA, state=ACTIVE/STANDBY
    if state in ("STARTED", "ACTIVE") or ha == "ACTIVE":
        return PASS, f"state={state or '-'} haState={ha or '-'}"
    if state in ("STOPPED", "STANDBY"):
        return FAIL, f"state={state} haState={ha or '-'}"
    return FAIL, f"estado={state or 'desconocido'}"


@check("yarn.nodemanager1", "NodeManager 1", "yarn", ["yarn.resourcemanager.state"])
def c_nm1():
    st = container_state("hl-nodemanager1")
    code, body = http_get("http://localhost:8042/ws/v1/node/info", 6)
    if st == "healthy" and code == 200:
        return PASS, "healthy + REST :8042"
    if code == 200:
        return DEGRADED, f"REST OK pero estado={st}"
    return FAIL, f"estado={st} http={code}"


@check("yarn.nodemanager2", "NodeManager 2", "yarn", ["yarn.resourcemanager.state"])
def c_nm2():
    st = container_state("hl-nodemanager2")
    code, body = http_get("http://localhost:8043/ws/v1/node/info", 6)
    if st == "healthy" and code == 200:
        return PASS, "healthy + REST :8043"
    if code == 200:
        return DEGRADED, f"REST OK pero estado={st}"
    return FAIL, f"estado={st} http={code}"


@check("yarn.nodes", "Nodos YARN registrados", "yarn",
       ["yarn.resourcemanager.state"], timeout=45)
def c_yarn_nodes():
    rc, out = compose_exec("yarn node -list -all", 40)
    if rc != 0:
        return FAIL, f"yarn node rc={rc}: {out.strip()[:100]}"
    running = sum(1 for ln in out.splitlines() if _is_node_row(ln, "RUNNING"))
    if running >= 2:
        return PASS, "2/2 nodos RUNNING"
    if running == 1:
        return DEGRADED, "1/2 nodos RUNNING"
    return FAIL, "0 nodos RUNNING"


def _is_node_row(line: str, state: str) -> bool:
    parts = line.split()
    return len(parts) >= 2 and parts[1] == state


@check("yarn.resources", "Recursos YARN", "yarn", ["yarn.resourcemanager.state"])
def c_yarn_resources():
    code, body = http_get("http://localhost:8088/ws/v1/cluster/metrics", 8)
    if code != 200:
        return FAIL, f"métricas HTTP {code}"
    try:
        m = json.loads(body)["clusterMetrics"]
    except Exception:
        return FAIL, "métricas ilegibles"
    avail, running, failed = m.get("availableMB", 0), m.get("appsRunning", 0), m.get("appsFailed", 0)
    detail = f"{avail} MB libres, {running} apps, {failed} fallidas"
    if avail <= 0:
        return DEGRADED, "sin memoria disponible (¿apps colgadas?) " + detail
    if failed > 0:
        return DEGRADED, detail
    return PASS, detail


@check("yarn.log_aggregation", "Agregación de logs YARN", "yarn", ["yarn.resourcemanager.state"])
def c_log_agg():
    cfg = LAB_ROOT / "config" / "hadoop" / "yarn-site.xml"
    try:
        text = cfg.read_text()
    except OSError as e:
        return FAIL, str(e)
    if "<name>yarn.log-aggregation-enable</name>" in text and "<value>true</value>" in text:
        return PASS, "habilitada en yarn-site.xml (/var/log/hadoop-yarn/apps)"
    return NOT_CONFIGURED, "deshabilitada en yarn-site.xml"


# ------------------------------------------------------------------ 4. Spark
@check("spark.client", "Cliente Spark", "spark", ["lab.containers"], timeout=30)
def c_spark_client():
    if container_state("hl-client") == "absent":
        return FAIL, "hl-client no existe"
    rc, out = compose_exec("test -x /opt/spark/bin/spark-submit && spark-submit --version", 25)
    if rc == 0:
        for line in out.splitlines():
            if "version" in line and "Spark" in line:
                return PASS, line.strip()[:70]
        return PASS, "spark-submit operativo"
    return FAIL, f"rc={rc}: {out.strip()[:100]}"


@check("spark.yarn.config", "Spark <-> YARN", "spark", ["spark.client", "yarn.resourcemanager.state"],
       timeout=30)
def c_spark_yarn():
    rc, out = compose_exec(
        "test -f /opt/lab/conf/yarn-site.xml && test -n \"$SPARK_HOME\" && "
        "ls /opt/spark/jars/spark-yarn_*.jar >/dev/null", 25)
    return (PASS, "yarn-site + SPARK_HOME + spark-yarn jar") if rc == 0 else \
           (FAIL, f"rc={rc}: {out.strip()[:120]}")


@check("spark.job", "Job Spark en YARN", "spark", ["spark.yarn.config", "yarn.nodes"],
       timeout=240, heavy=True)
def c_spark_job():
    cmd = ("spark-submit --master yarn --deploy-mode client "
           "--executor-memory 512m --executor-cores 1 --driver-memory 512m "
           "--conf spark.sql.shuffle.partitions=4 "
           "/opt/spark/examples/src/main/python/pi.py 16")
    rc, out = compose_exec(cmd, 220)
    if "Pi is roughly" in out:
        return PASS, "job pi completado en YARN"
    if rc == 124:
        return DEGRADED, "job pi agotó el tiempo (¿recursos insuficientes?)"
    return FAIL, f"rc={rc}: {out.strip()[-180:]}"


# ------------------------------------------------------------------ 5. observabilidad
@check("obs.metrics.nn", "Métricas NameNode", "observabilidad", ["hdfs.namenode.http"])
def c_obs_nn():
    code, body = http_get("http://localhost:9870/jmx", 8)
    if code != 200:
        return FAIL, f"HTTP {code}"
    if "Hadoop:service=NameNode" in body:
        return PASS, "beans JMX del NameNode disponibles"
    return DEGRADED, "JMX responde sin beans del NameNode"


@check("obs.metrics.rm", "Métricas ResourceManager", "observabilidad",
       ["yarn.resourcemanager.rest"])
def c_obs_rm():
    code, body = http_get("http://localhost:8088/jmx", 8)
    if code == 200 and "ResourceManager" in body:
        return PASS, "beans JMX del ResourceManager"
    return (FAIL, f"HTTP {code}") if code == 0 else (DEGRADED, f"HTTP {code}")


@check("obs.metrics.exporter", "Exportador Prometheus", "observabilidad",
       ["lab.containers"], timeout=15)
def c_obs_exporter():
    code, body = http_get("http://localhost:9871/metrics", 8)
    if code != 200:
        return FAIL, f"HTTP {code} en :9871/metrics"
    if "hadoop_lab_scrape_targets_up" not in body:
        return DEGRADED, "endpoint sin métricas hadoop_lab_*"
    for line in body.splitlines():
        if line.startswith("hadoop_lab_scrape_targets_up"):
            up = line.rsplit(" ", 1)[-1]
            if up == "6":
                return PASS, "6/6 componentes convertidas a Prometheus"
            return DEGRADED, f"{up}/6 componentes en :9871/metrics"
    return DEGRADED, "sin hadoop_lab_scrape_targets_up"


@check("obs.logs", "Logs persistentes", "observabilidad", ["lab.containers"])
def c_obs_logs():
    newest, count = 0.0, 0
    for d in LOGS.glob("*/"):
        for f in d.glob("*"):
            if f.is_file():
                count += 1
                newest = max(newest, f.stat().st_mtime)
    if count == 0:
        return FAIL, "sin ficheros de log en ./data/logs"
    age = int(time.time() - newest)
    if age > 3600:
        return DEGRADED, f"{count} ficheros, el más reciente con {age}s de antigüedad"
    return PASS, f"{count} ficheros de log (último hace {age}s)"


@check("obs.prometheus", "Prometheus (reutilizado)", "observabilidad", [], timeout=15)
def c_prom():
    code, body = http_get("http://localhost:9091/-/healthy", 6)
    if code == 200:
        return PASS, ":9091 healthy (gcp-architecture-lab)"
    if code == 0:
        return DEGRADED, "Prometheus vecino no responde (¿stack parado?)"
    return DEGRADED, f"HTTP {code}"


@check("obs.grafana", "Grafana (reutilizado)", "observabilidad", [], timeout=15)
def c_grafana():
    code, _ = http_get("http://localhost:3001/api/health", 6)
    if code == 200:
        return PASS, ":3001 healthy (gcp-architecture-lab)"
    if code == 0:
        return DEGRADED, "Grafana vecino no responde (¿stack parado?)"
    return DEGRADED, f"HTTP {code}"


# ------------------------------------------------------------------ 6. integración
@check("integration.spark_standalone", "Spark standalone (vecino)", "integracion", [],
       timeout=15)
def c_spark_std():
    if not tcp_open("127.0.0.1", 7077, 4):
        return DEGRADED, "puerto 7077 cerrado (de-spark-master detenido)"
    code, _ = http_get("http://localhost:18080/", 6)
    return (PASS, "master :7077 + WebUI :18080 (data-eng-lab)") if code in (200, 302) \
        else (DEGRADED, f"RPC abierto pero WebUI HTTP {code}")


@check("integration.airflow", "Airflow (vecino)", "integracion", [], timeout=15)
def c_airflow():
    code, _ = http_get("http://localhost:8080/health", 6)
    if code == 200:
        return PASS, ":8080/health OK (data-eng-lab)"
    if code == 0:
        return DEGRADED, "Airflow vecino no responde"
    return DEGRADED, f"HTTP {code}"


@check("integration.postgres", "PostgreSQL del laboratorio", "integracion", [])
def c_pg():
    return NOT_CONFIGURED, "el lab no usa SQL hoy (ver docs/integration.md §1)"


@check("integration.messaging", "Mensajería (Kafka/RabbitMQ)", "integracion", [])
def c_mq():
    return NOT_CONFIGURED, "no existe en el equipo y el lab no lo requiere"


@check("integration.log_backend", "Backend de logs central (Loki/OTel)", "integracion", [])
def c_loki():
    return NOT_CONFIGURED, "sin Loki/OTel: logs en ./data/logs (ver docs/architecture.md §8)"


# ------------------------------------------------------------------ motor
def topological_ok(checks: list[Check]) -> list[str]:
    ids = {c.id for c in checks}
    errors = []
    for c in checks:
        for d in c.deps:
            if d not in ids:
                errors.append(f"{c.id} depende de '{d}' que no está en la selección")
    return errors


def run_iteration(checks: list[Check], color_on: bool, quick: bool) -> dict:
    results: dict[str, str] = {}
    rows = []
    started = time.time()

    for c in checks:
        t0 = time.time()
        blocked = next((d for d in c.deps if results.get(d) == FAIL), None)
        if blocked:
            state, detail = FAIL, f"bloqueado por FAIL en '{blocked}'"
            c.blocked_by = blocked
        elif c.heavy and quick:
            state, detail = NOT_CONFIGURED, "omitido con --quick (usa sin --quick para ejecutarlo)"
        else:
            try:
                state, detail = c.func()
            except Exception as e:  # una comprobación rota no detiene la cadena
                state, detail = FAIL, f"excepción: {type(e).__name__}: {e}"
            if state not in STATES:
                state, detail = FAIL, f"estado inválido '{state}'"
        dur = int((time.time() - t0) * 1000)
        c.result, c.duration_ms = (state, detail), dur
        results[c.id] = state
        rows.append({
            "id": c.id, "name": c.name, "group": c.group, "state": state,
            "detail": detail, "duration_ms": dur, "deps": c.deps,
            "blocked_by": c.blocked_by,
        })
        label = f"{state:<16}"
        if color_on:
            label = f"{COLORS[state]}{label}{RESET}"
        print(f"  {label} {c.id:<34} {detail}")

    summary = {s: sum(1 for r in rows if r["state"] == s) for s in STATES}
    return {
        "generated_at": now(),
        "duration_ms": int((time.time() - started) * 1000),
        "summary": summary,
        "checks": rows,
    }


def write_json(report: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")


def write_prom(report: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# hadoop-platform-lab: resultado de la cadena de validación",
             "# HELP hadoop_lab_check_state Estado de cada comprobación (1 en la etiqueta state).",
             "# TYPE hadoop_lab_check_state gauge"]
    for c in report["checks"]:
        lines.append(f'hadoop_lab_check_state{{check="{c["id"]}",group="{c["group"]}",'
                     f'state="{c["state"]}"}} 1')
    lines.append("# TYPE hadoop_lab_validation_summary gauge")
    for s in STATES:
        lines.append(f'hadoop_lab_validation_summary{{state="{s}"}} '
                     f'{report["summary"][s]}')
    lines.append("# TYPE hadoop_lab_validation_duration_seconds gauge")
    lines.append(f'hadoop_lab_validation_duration_seconds {report["duration_ms"] / 1000:.3f}')
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true", help="omite el job pesado de Spark")
    ap.add_argument("--loop", type=int, default=1, metavar="N",
                    help=f"iteraciones (1 por defecto, tope {MAX_LOOP})")
    ap.add_argument("--interval", type=float, default=30.0, metavar="S",
                    help="segundos entre iteraciones (mínimo 1)")
    ap.add_argument("--only", action="append", default=[], metavar="ID",
                    help="ejecuta sólo estas comprobaciones (repetible)")
    ap.add_argument("--list", action="store_true", help="lista las comprobaciones y sale")
    ap.add_argument("--no-color", action="store_true")
    ap.add_argument("--json", metavar="PATH", help="ruta del informe JSON")
    ap.add_argument("--prom", metavar="PATH", help="ruta de la métrica textfile")
    args = ap.parse_args()

    if args.list:
        for c in CHECKS:
            heavy = " [pesado]" if c.heavy else ""
            deps = ", ".join(c.deps) or "-"
            print(f"{c.id:<34} [{c.group}] deps={deps}{heavy}")
        return 0

    if args.loop < 1 or args.loop > MAX_LOOP:
        print(f"ERROR: --loop debe estar entre 1 y {MAX_LOOP}", file=sys.stderr)
        return 2
    if args.interval < MIN_INTERVAL:
        print(f"ERROR: --interval mínimo {MIN_INTERVAL}s", file=sys.stderr)
        return 2

    checks = CHECKS if not args.only else [c for c in CHECKS if c.id in args.only]
    if not checks:
        print("ERROR: ningún --only coincide con una comprobación", file=sys.stderr)
        return 2
    problems = topological_ok(checks)
    if problems:
        print("ERROR: dependencias fuera de la selección:\n  " + "\n  ".join(problems),
              file=sys.stderr)
        return 2

    color_on = sys.stdout.isatty() and not args.no_color and not os.environ.get("NO_COLOR")
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    suffix = f"-i{i:02d}" if args.loop > 1 else ""
    json_path = Path(args.json) if args.json else REPORTS / f"validation-{ts}{suffix}.json"
    prom_path = Path(args.prom) if args.prom else METRICS / "validation.prom"

    overall_fail = False
    degraded_only = False
    for i in range(1, args.loop + 1):
        guard = time.time() + ITERATION_GUARD
        head = f"iteración {i}/{args.loop} — {now()}"
        print(f"{BOLD}{head}{RESET}" if color_on else head)
        report = run_iteration(checks, color_on, args.quick)
        report["iteration"] = i
        report["iterations"] = args.loop
        if args.loop > 1 and not args.json:
            json_path = REPORTS / f"validation-{ts}-i{i:02d}.json"
        write_json(report, json_path)
        write_prom(report, prom_path)

        s = report["summary"]
        print(f"  {'resumen':<16} PASS={s[PASS]} FAIL={s[FAIL]} "
              f"DEGRADED={s[DEGRADED]} NOT_CONFIGURED={s[NOT_CONFIGURED]} "
              f"({report['duration_ms']} ms)")
        print(f"  informe: {json_path}")
        print(f"  métrica: {prom_path}\n")
        if s[FAIL]:
            overall_fail = True
        elif s[DEGRADED] and not degraded_only:
            degraded_only = True
        if i < args.loop:
            if time.time() > guard:
                print("  (tope de iteración alcanzado: se pasa a la siguiente)")
            time.sleep(max(args.interval, MIN_INTERVAL))

    # Códigos de salida: 0 = sin incidencias, 1 = algún FAIL,
    # 2 = error de uso, 3 = sin FAIL pero con algún DEGRADED.
    if overall_fail:
        return 1
    return 3 if degraded_only else 0


if __name__ == "__main__":
    sys.exit(main())
