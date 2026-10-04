#!/usr/bin/env python3
"""Exportador de métricas JMX de Hadoop a formato Prometheus.

Hadoop expone sus métricas como JSON en ``/jmx`` (no en formato Prometheus),
por lo que este servicio las convierte bajo demanda. Se ejecuta dentro de la
red ``hadoop_lab`` y publica un único endpoint scrapeable:

    GET /metrics   métricas en texto Prometheus (todas las componentes)
    GET /health    sonda de salud (usada por el healthcheck del contenedor)

Modo offline (para consumidores tipo textfile, p. ej. node_exporter):

    python3 exporter.py --once --output ../data/metrics/hadoop-lab.prom

Sin dependencias externas: solo la biblioteca estándar de Python 3.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

DEFAULT_TARGETS = (
    "namenode=namenode:9870",
    "resourcemanager=resourcemanager:8088",
    "datanode1=datanode1:9864",
    "datanode2=datanode2:9864",
    "nodemanager1=nodemanager1:8042",
    "nodemanager2=nodemanager2:8042",
)

# Beans cuyo contenido interesa; el resto (HTTP server, MetricsSystem,
# delegaciones de tokens, etc.) se ignora para no inundar a Prometheus.
BEAN_ALLOW = (
    r"Hadoop:service=NameNode,name=(FSNamesystem|FSNamesystemState"
    r"|NameNodeActivity|NameNodeInfo|RpcActivityForPort8020|JvmMetrics)$",
    r"Hadoop:service=ResourceManager,name=(ClusterMetrics"
    r"|QueueMetrics,q0=root,q1=default|JvmMetrics)$",
    r"Hadoop:service=DataNode,name=(FSDatasetState|DataNodeInfo|JvmMetrics)$",
    r"Hadoop:service=NodeManager,name=(NodeManagerMetrics|JvmMetrics)$",
)
BEAN_RE = tuple(re.compile(p) for p in BEAN_ALLOW)
NUM_RE = re.compile(r"^-?\d+(\.\d+)?$")
DESC = {
    "livedatanodes": "DataNodes vivos reportados por el NameNode",
    "deaddatanodes": "DataNodes caídos reportados por el NameNode",
    "capacitytotal": "Capacidad total del sistema de ficheros (bytes)",
    "capacityused": "Capacidad usada (bytes)",
    "capacityremaining": "Capacidad restante (bytes)",
    "blockstotal": "Bloques almacenados",
    "filestotal": "Ficheros totales",
    "safemode": "1 si el NameNode está en safe mode",
    "appsrunning": "Aplicaciones YARN en ejecución",
    "appspending": "Aplicaciones YARN pendientes",
    "appsfailed": "Aplicaciones YARN fallidas",
    "availablemb": "Memoria MB disponible en la cola YARN",
    "allocatedmb": "Memoria MB asignada en la cola YARN",
    "containersrunning": "Contenedores YARN en ejecución",
    "memheapusedm": "Heap JVM usado (MB)",
    "memheapmaxm": "Heap JVM máximo (MB)",
}


def parse_targets(raw: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        name, _, addr = item.partition("=")
        out[name.strip()] = addr.strip() if addr else item
    return out


def sanitize(value: str) -> str:
    value = re.sub(r"[^0-9A-Za-z]+", "_", value).strip("_").lower()
    return re.sub(r"_{2,}", "_", value)


def short_bean(bean: str) -> str:
    """'Hadoop:service=NameNode,name=FSNamesystem' -> 'fs_namesystem'."""
    name = bean.split("name=", 1)[1] if "name=" in bean else bean
    name = name.split(",", 1)[0]
    return sanitize(name)


def as_number(value):
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str) and NUM_RE.match(value.strip()):
        return float(value.strip())
    return None


def fetch(url: str, timeout: float) -> list[dict]:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        payload = json.load(resp)
    beans = payload.get("beans")
    if not isinstance(beans, list):
        raise ValueError("respuesta /jmx sin 'beans'")
    return beans


def scrape_one(component: str, addr: str, timeout: float):
    """Devuelve (metricas, ok, duracion). metricas: [(nombre, etiquetas, valor)]."""
    started = time.monotonic()
    metrics: list[tuple[str, dict[str, str], float]] = []
    try:
        url = addr if addr.startswith("http") else f"http://{addr}/jmx"
        beans = fetch(url, timeout)
    except Exception as exc:  # noqa: BLE001 — el error se expone como métrica
        duration = time.monotonic() - started
        labels = {"component": component}
        return (
            [
                ("hadoop_lab_scrape_success", labels, 0.0),
                ("hadoop_lab_scrape_error", {**labels, "error": sanitize(str(exc))[:60]}, 1.0),
                ("hadoop_lab_scrape_duration_seconds", labels, duration),
            ],
            False,
            duration,
        )

    for bean in beans:
        bean_name = str(bean.get("name", ""))
        if not any(rx.match(bean_name) for rx in BEAN_RE):
            continue
        bshort = short_bean(bean_name)
        for attr, raw in bean.items():
            if attr in ("name", "modelerType", "tag.Context", "tag.Hadoop"):
                continue
            value = as_number(raw)
            if value is None:
                continue
            metric = f"hadoop_lab_{sanitize(attr)}"
            labels = {
                "component": component,
                "service": bean_name.split("service=", 1)[1].split(",", 1)[0]
                if "service=" in bean_name
                else bshort,
                "bean": bshort,
            }
            metrics.append((metric, labels, value))

    duration = time.monotonic() - started
    labels = {"component": component}
    metrics.append(("hadoop_lab_scrape_success", labels, 1.0))
    metrics.append(("hadoop_lab_scrape_duration_seconds", labels, duration))
    return metrics, True, duration


def scrape_all(targets: dict[str, str], timeout: float):
    all_metrics: list[tuple[str, dict[str, str], float]] = []
    ok_count = 0
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=max(4, len(targets))) as pool:
        futures = [
            (name, pool.submit(scrape_one, name, addr, timeout))
            for name, addr in targets.items()
        ]
        for name, fut in futures:
            metrics, ok, _ = fut.result()
            all_metrics.extend(metrics)
            ok_count += 1 if ok else 0
    all_metrics.append(
        ("hadoop_lab_scrape_targets_up", {"state": "up"}, float(ok_count))
    )
    all_metrics.append(
        ("hadoop_lab_scrape_targets_total", {"state": "total"}, float(len(targets)))
    )
    all_metrics.append(
        (
            "hadoop_lab_scrape_collection_seconds",
            {},
            time.monotonic() - started,
        )
    )
    return all_metrics, ok_count, len(targets)


def escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def render(metrics: list[tuple[str, dict[str, str], float]]) -> str:
    families: dict[str, list[tuple[dict[str, str], float]]] = {}
    for name, labels, value in metrics:
        families.setdefault(name, []).append((labels, value))

    lines: list[str] = []
    for name in sorted(families):
        lines.append(f"# TYPE {name} gauge")
        desc_key = name.removeprefix("hadoop_lab_")
        if desc_key in DESC:
            lines.append(f"# HELP {name} {DESC[desc_key]}")
        for labels, value in families[name]:
            label_str = ",".join(
                f'{k}="{escape_label(v)}"' for k, v in sorted(labels.items())
            )
            rendered = int(value) if float(value).is_integer() else value
            lines.append(f"{name}{{{label_str}}} {rendered}")
    lines.append("")
    return "\n".join(lines)


def serve(port: int, targets: dict[str, str], timeout: float) -> None:
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Handler(BaseHTTPRequestHandler):
        server_version = "hadoop-platform-lab-exporter/0.1.0"

        def _send(self, code: int, body: str, ctype: str) -> None:
            data = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:  # noqa: N802
            if self.path in ("/health", "/-/healthy"):
                self._send(200, "ok\n", "text/plain; charset=utf-8")
                return
            if self.path in ("/metrics", "/"):
                metrics, ok, total = scrape_all(targets, timeout)
                self._send(
                    200,
                    render(metrics),
                    "text/plain; version=0.0.4; charset=utf-8",
                )
                if ok < total:
                    print(
                        f"[exporter] {total - ok}/{total} componentes sin JMX",
                        file=sys.stderr,
                        flush=True,
                    )
                return
            self._send(404, "no encontrado\n", "text/plain; charset=utf-8")

        def log_message(self, fmt: str, *args) -> None:
            print(f"[exporter] {self.address_string()} {fmt % args}", file=sys.stderr)

    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(
        f"[exporter] escuchando en :{port} — {len(targets)} componentes",
        file=sys.stderr,
        flush=True,
    )
    httpd.serve_forever()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=9871)
    parser.add_argument("--targets", default=",".join(DEFAULT_TARGETS))
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument(
        "--once",
        action="store_true",
        help="una sola pasada: imprime las métricas y sale (modo textfile)",
    )
    parser.add_argument("--output", help="fichero de salida de --once")
    args = parser.parse_args()

    targets = parse_targets(args.targets)
    if not targets:
        print("ERROR: sin objetivos", file=sys.stderr)
        return 2

    if args.once:
        metrics, ok, total = scrape_all(targets, args.timeout)
        text = render(metrics)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as fh:
                fh.write(text)
            print(f"{args.output}: {len(metrics)} métricas ({ok}/{total} componentes)")
        else:
            sys.stdout.write(text)
        return 0 if ok == total else 1

    serve(args.port, targets, args.timeout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
