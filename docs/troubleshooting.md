# Troubleshooting — Hadoop Platform Lab

Procedimiento de diagnóstico y el registro de los fallos realmente
encontrados durante la construcción del laboratorio (síntoma → causa →
solución → verificación). Operación diaria: `docs/operations.md`.

## 1. Árbol de diagnóstico (siempre en este orden)

```
1. ./scripts/validate/validate.py --quick     ¿EN QUÉ ESTÁ y en qué estado?
      │  FAIL      → punto concreto de la cadena (nombre del check)
      │  DEGRADED  → vivo pero incompleto (nodo caído, puerto sin publicar…)
      │  NOT_CONFIGURED → ausente por diseño (no es un fallo)
      ▼
2. ./scripts/diagnostics/diagnose.sh <servicio>   ¿estado del contenedor, OOM,
      │                                            reinicios, errores de log?
      ▼
3. ./scripts/diagnostics/logs.sh <servicio> --errors --lines 50
      │                        ¿qué dice el daemon?
      ▼
4. ./scripts/lab/status.sh     ¿puertos, endpoints y recursos (docker stats)?
      ▼
5. ./scripts/diagnostics/collect.sh   paquete .tar.gz con todo lo anterior
```

Los estados distinguen tres cosas distintas: **no existe** (NOT_CONFIGURED),
**existe y está mal** (FAIL), **existe pero incompleto** (DEGRADED). No hay que
confundir DEGRADED con FAIL: DEGRADED sale con código de salida `3`, FAIL con
`1`.

## 2. Códigos de salida y lectura del informe

| Código | Significado | Acción |
|---|---|---|
| `0` | todo PASS/NOT_CONFIGURED | nada |
| `1` | algún `FAIL` | incidencia real: mirar el check que falló |
| `2` | error de uso | argumentos o dependencias de `--only` fuera de selección |
| `3` | sin FAIL pero con `DEGRADED` | revisar qué está incompleto |

Informe: `data/reports/validation-<ISO>.json` → `checks[]` con `id`, `state`,
`message`, `duration_ms`, `deps`. Métrica: `data/metrics/validation.prom`.

## 3. Incidencias resueltos durante la construcción

Cada una se reprodujo, se diagnosticó y se corrigió; quedan documentadas para
reconocerlas si vuelven.

| # | Síntoma | Causa | Solución | Verificación |
|---|---|---|---|---|
| 1 | `docker build` aborta: `set: Illegal option -o pipefail` | la imagen base usa `/bin/sh` (dash), que no soporta `set -o pipefail` | `SHELL ["/bin/bash", "-c"]` antes del `RUN` en `docker/Dockerfile.client` | `docker compose build client` termina en 0 |
| 2 | El contenedor `hl-client` entra en bucle de reinicio (`created → running → restart`) | `SPARK_CONF_DIR` apuntaba a la config montada en solo lectura y el `envtoconf.py` de la imagen base intentaba escribir ahí | eliminado `SPARK_CONF_DIR` del `ENV` (Hadoop usa `HADOOP_CONF_DIR=/opt/lab/conf`) | `docker compose up -d client` → `healthy` y estable |
| 3 | `hl-nodemanager*` nunca pasa a `healthy` (arranca y muere el healthcheck) | el healthcheck grepeaba `RUNNING`, valor que solo aparece en `yarn node -list`, no en la REST del NM | healthcheck → `curl -sf .../ws/v1/node/info \| grep -q 'nodeHealthy.:true'` | `docker inspect hl-nodemanager1` → `healthy` |
| 4 | El healthcheck/validación del ResourceManager no encuentra `state=ACTIVE` | sin HA, Hadoop responde `state=STARTED` + `haState=ACTIVE`; `state=ACTIVE` solo existe en clústeres HA | comprobación sobre `state.:.STARTED` (compose) y `state=STARTED haState=ACTIVE` (validate) | `validate.py --only yarn.resourcemanager.state` → PASS |
| 5 | Al parar un DataNode, el NameNode sigue diciendo `Live datanodes (2)` durante ~10 min | por defecto `dfs.heartbeat.interval=300` y `dfs.namenode.heartbeat.recheck-interval=300000` | `hdfs-site.xml`: heartbeat 5 s, recheck 30 s, stale 15 s | `docker compose stop datanode2` → en ≤60 s `Live datanodes (1)` |
| 6 | El ResourceManager muere al arrancar: `Queue configuration missing child queue names for root` | falta `capacity-scheduler.xml` (Hadoop 3 no arranca RM sin el árbol de colas) | añadido `config/hadoop/capacity-scheduler.xml` con `root.default` | `hl-resourcemanager` → `healthy`; `yarn queue -status root.default` responde |
| 7 | `docker compose` falla: `did not find expected '-' indicator` (línea ~247) | un bloque de servicio quedó con indentación incorrecta al editar `compose.yaml` | indentación corregida (los hijos de `client:` vuelven a 4 espacios) | `docker compose config --services` lista los 8 servicios |
| 8 | `health/spark.sh` → `FAIL spark.client.version (no se pudo leer la versión)` | `spark-submit --version` escribe en **stderr** y `exec_client` descarta stderr | redirección dentro del comando remoto: `spark-submit --version 2>&1` | `./scripts/health/spark.sh` → PASS (Spark 3.5.3) |
| 9 | `logs.sh` imprime `hint: command not found` y errores raros de `xargs` | `hint` solo existía en `diagnose.sh`, y `xargs -I{}` no puede invocar funciones de shell | `hint()` movido a `scripts/lib/common.sh`; el recuento usa una variable, no `xargs` | `logs.sh <svc> --errors` termina limpio |
| 10 | `diagnose.sh namenode` → `DEGRADED` aunque todo estuviera bien | el apagado limpio se registra como `ERROR ... RECEIVED SIGNAL 15: SIGTERM` | se excluye `RECEIVED SIGNAL` del filtro de errores | `diagnose.sh namenode` → `PASS sin anomalías evidentes` |
| 11 | El check `obs.metrics.exporter` decía `endpoint sin métricas hadoop_lab_*` aunque `curl` las mostraba | `http_get` solo leía 8192 bytes y las métricas de resumen van al final | lectura hasta 256 KiB | `validate.py --only ...` → PASS 6/6 componentes |
| 12 | Conflicto de puertos al planear el stack | `8082` (evolution-api) y `3000` (waha) ya estaban en uso | `LAB_PORTS` solo con puertos verificados libres; `up.sh` los comprueba antes de arrancar | `./scripts/inventory/ports.sh` → `PASS sin conflictos` |
| 13 | Los daemons no podían escribir en `./data` si el directorio no existía | Docker crea los bind mounts como `root` cuando faltan | `ensure_dirs` en `up.sh` crea `./data/**` con `uid 1000` (== `hadoop`) antes de arrancar | `./scripts/inventory/system.sh` → `PASS permisos de datos correctos` |

## 4. Síntomas frecuentes y qué mirar

| Síntoma | Causa probable | Qué ejecutar |
|---|---|---|
| `FAIL docker.daemon` | Docker parado en WSL | `sudo service docker start` o reiniciar WSL |
| `FAIL lab.port_conflicts` | un puerto de `LAB_PORTS` lo ocupa otro proceso | `ss -ltnp \| grep -E '8020\|9870\|9871'` ; `./scripts/inventory/ports.sh` |
| `DEGRADED lab.containers (faltan: hl-x)` | contenedor caído | `docker ps -a --filter name=hl-` → `docker compose start <servicio>` |
| `FAIL hdfs.datanode2 (estado=unhealthy)` | DN detenido o muerto | `docker logs --tail 50 hl-datanode2`; `./scripts/diagnostics/diagnose.sh datanode2` |
| `DEGRADED hdfs.datanodes.live (1/2)` | un DN caído (esperado en drill) | `docker compose start datanode2` y esperar `dfsadmin -report` |
| `FAIL hdfs.safemode` | NN en safe mode (arranque reciente o bloques perdidos) | `hdfs dfsadmin -safemode get`; si no sale solo: `-leave` tras revisar `hdfs fsck /` |
| `FAIL hdfs.write_read` | NN parado, safe mode, o sin nodos con capacidad | `docker logs hl-namenode`, `hdfs dfsadmin -report` |
| `DEGRADED yarn.nodes (1/2)` | NM caído | `docker logs hl-nodemanager2` |
| Job Spark falla con `Invalid resource request...` | petición de memoria > `yarn.scheduler.maximum-allocation-mb` (1536) | bajar `--executor-memory`/`--driver-memory` (p. ej. 512m) |
| Job Spark falla con `Container [...] is running beyond memory limits` | límite de contenedor; los checks de pmem están desactivados, pero el contenedor se mata | revisar `docker stats` y subir el límite del NM en `compose.yaml` |
| `DEGRADED integration.spark_standalone` | el vecino `azure-data-engineering-lab` está parado | no afecta a este lab: es comprobación de solo lectura |
| `NOT_CONFIGURED ...` | componente ausente por diseño | nada: está clasificado en `docs/integration.md` |
| `hl-metrics` responde pero `targets_up < 6` | algún daemon sin `/jmx` | `curl -s localhost:9871/metrics \| grep scrape_error` (trae el motivo) |
| Espacio de `./data` creciendo | logs o trabajos YARN | `du -sh data/*`; `yarn application -list` y `-kill` de restos |
| Tras `reset.sh`, HDFS sale vacío | se borraron `data/` a propósito | restaurar copia (`docs/operations.md` §9) |

## 5. Recetas de recuperación

```bash
# stack completo herido → parar, revisar, arrancar limpio (conserva datos)
./scripts/lab/down.sh
./scripts/diagnostics/collect.sh       # evidencias ANTES de tocar nada
./scripts/lab/up.sh 300

# NameNode no arranca: mirar si el formato es válido
docker logs hl-namenode 2>&1 | tail -30
cat data/namenode/current/VERSION      # debe tener clusterID y blockID

# borrar TODO y empezar de cero (IRREVERSIBLE)
./scripts/lab/reset.sh --yes && ./scripts/lab/up.sh
```

## 6. Recopilar evidencias (antes de pedir ayuda o de cambiar cosas)

```bash
./scripts/diagnostics/collect.sh
# → data/reports/diag-<ISO>.tar.gz
#   estado de contenedores, JMX/REST de NN/RM/DN/NM, dfsadmin, yarn,
#   errores de log, red y puertos

./scripts/validate/validate.py --no-color > data/reports/validacion.txt 2>&1
./scripts/lab/status.sh > data/reports/estado.txt 2>&1
```

Regla de oro: **recoger evidencias antes de reiniciar**. `docker logs` y
`./data/logs/<servicio>/` sobreviven a un reinicio del contenedor, pero un
`reset.sh` los borra.
