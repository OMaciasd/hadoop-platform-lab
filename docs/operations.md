# Operaciones — Hadoop Platform Lab

Runbook de uso diario. Instalación y arquitectura: `README.md` y
`docs/architecture.md`. Incidencias: `docs/troubleshooting.md`.

Convenio de todos los comandos: se ejecutan desde la raíz del repo
(`~/projects/hadoop-platform-lab`). `client` es el contenedor con las CLIs
(HDFS + YARN + Spark); los daemons se manejan con `docker compose`.

## 1. Ciclo de vida del stack

```bash
./scripts/lab/up.sh              # comprueba puertos, crea ./data, arranca y espera healthchecks
./scripts/lab/up.sh 300          # mismo, con tope de espera de 300 s
./scripts/lab/status.sh          # contenedores, endpoints HTTP, recursos (docker stats)
./scripts/lab/down.sh            # para todo; los datos de ./data persisten
./scripts/lab/reset.sh           # PARA Y BORRA ./data (pide confirmación; --yes para no preguntar)
```

`up.sh` solo arranca si `LAB_PORTS` (8020, 8042, 8043, 8088, 9864, 9865, 9870,
9871) está libre: no puede pisar a otro proyecto.

Arranque pieza a pieza (útil para drills):

```bash
docker compose up -d namenode          # primero el NameNode (los demás esperan con WAITFOR)
docker compose stop datanode2          # simular caída de un nodo
docker compose start datanode2         # recuperar
docker compose restart resourcemanager # reinicio puntual del RM
```

## 2. Mapa de acceso

| Qué | URL / comando | Puerto host |
|---|---|---|
| NameNode UI / JMX / WebHDFS | http://localhost:9870 | 9870 |
| NameNode RPC (cliente HDFS) | `namenode:8020` (interno), `localhost:8020` | 8020 |
| DataNode 1 / 2 UI | http://localhost:9864 / http://localhost:9865 | 9864/9865 |
| ResourceManager UI / REST | http://localhost:8088, `/ws/v1/cluster/{info,metrics,nodes}` | 8088 |
| NodeManager 1 / 2 REST | http://localhost:8042 / http://localhost:8043 | 8042/8043 |
| Exportador Prometheus | http://localhost:9871/metrics, `/health` | 9871 |
| Spark standalone (vecino, solo lectura) | http://localhost:18080 | 18080/7077 |
| Prometheus / Grafana (vecinos) | http://localhost:9091 / http://localhost:3001 | 9091/3001 |

## 3. HDFS en el día a día

```bash
# atajo: siempre a través del cliente
d() { docker compose exec -T client timeout 60 bash -lc "hdfs dfs $*"; }
a() { docker compose exec -T client timeout 60 bash -lc "hdfs dfsadmin $*"; }

d -ls /                     # listar
d -mkdir -p /lab/ejemplo    # crear directorio
d -put archivo.txt /lab/    # subir
d -cat /lab/archivo.txt     # leer
d -du -s /                  # uso por directorio
d -setrep -w 3 /lab/archivo.txt   # subir réplica temporalmente (hay 2 nodos: 3 no se cumple)

a -report                   # nodos, capacidad, bloques
a -safemode get|enter|leave # estado/apagado del safe mode
a -refreshNodes             # recargar include/exclude (si se configura decommission)
docker compose exec -T namenode timeout 60 bash -lc 'hdfs fsck / -files -blocks'   # integridad
docker compose exec -T namenode timeout 60 bash -lc 'hdfs dfsadmin -finalizeUpgrade'
```

Notas operativas del laboratorio:

- `dfs.replication=2` con 2 DataNodes: la réplica 2 **se cumple**; si cae un
  nodo, los bloques quedan sub-replicados (no perdidos) y se replican solos
  al volver.
- `dfs.permissions.enabled=false` (ver `config/hadoop/hdfs-site.xml`): para
  practicar permisos/ACLs hay que ponerlo a `true` y reiniciar el NameNode.
- WebHDFS está habilitado: `curl 'http://localhost:9870/webhdfs/v1/lab?op=LISTSTATUS'`.
- No hay HA: hay **un solo NameNode**. Su estado es `data/namenode/current/`.

## 4. YARN en el día a día

```bash
y() { docker compose exec -T client timeout 60 bash -lc "yarn $*"; }

y node -list                  # nodos y contenedores en marcha
y node -status nodemanager1:33059
y application -list           # aplicaciones
y application -status <app_id>
y application -kill <app_id>
y queue -status root.default  # cola por defecto (capacity-scheduler.xml)
y container -status <container_id>
y logs -applicationId <app_id>            # logs agregados en HDFS (aggregation ON)
y logs -applicationId <app_id> -n 200     # últimas 200 líneas
y rmadmin -refreshQueues                  # recargar capacity-scheduler.xml en caliente
```

Recursos: `yarn.nodemanager.resource.memory-mb=1536`, `cpu-vcores=4` por nodo
→ techo de **3072 MB / 4 vcores** en total. Asignación mínima 128 MB, máxima
1536 MB (`yarn-site.xml`). Cola `root.default` con
`yarn.scheduler.maximum-allocation-mb=1536`.

## 5. Spark sobre YARN

```bash
docker compose exec -T client bash -lc '
  spark-submit --master yarn --deploy-mode client \
    --executor-memory 512m --executor-cores 1 --driver-memory 512m \
    /opt/spark/examples/src/main/python/pi.py 16'
```

- `--deploy-mode cluster` también funciona (el AM sale en un NodeManager).
- Ver la aplicación resultante: `yarn application -list` y su UI en `:8088`.
- Logs de la app: `yarn logs -applicationId application_<id>`.
- No hay Spark History Server configurado: los trabajos pasados se ven por
  `yarn logs`, no por una UI histórica.
- El Spark **standalone** de `azure-data-engineering-lab` (`:7077`) se usa solo
  como servicio vecino comprobado en la validación: no se ejecutan jobs ahí.

## 6. Logs y diagnóstico

```bash
./scripts/diagnostics/diagnose.sh <namenode|datanode1|...|red|disk|puertos>
./scripts/diagnostics/logs.sh <servicio> --errors --lines 50
./scripts/diagnostics/logs.sh <servicio> --follow
./scripts/diagnostics/collect.sh          # paquete .tar.gz con estado + JMX + logs
```

Los logs viven en `./data/logs/<servicio>/` (rotación 64 MB × 10, ver
`config/hadoop/log4j.properties`) y también en `docker logs hl-<servicio>`.

## 7. Validación

```bash
./scripts/validate/validate.py                 # cadena completa (incluye job Spark pi)
./scripts/validate/validate.py --quick         # sin job pesado (~70 s)
./scripts/validate/validate.py --loop 5 --interval 60     # 5 iteraciones, luego para
./scripts/validate/validate.py --only hdfs.safemode --only hdfs.namenode.http
./scripts/validate/validate.py --no-color      # para CI/registro
```

Estados: `PASS` · `FAIL` · `DEGRADED` (vivo pero incompleto) ·
`NOT_CONFIGURED` (ausente por diseño: Postgres, Kafka, Loki…).

Códigos de salida: `0` sin incidencias · `1` algún `FAIL` · `2` error de uso
(argumentos o dependencias de `--only`) · `3` sin `FAIL` pero con `DEGRADED`.

Artefactos: `data/reports/validation-<ISO>.json` (detalle por check) y
`data/metrics/validation.prom` (textfile para Prometheus).

Los loops son **acotados siempre**: sin `--loop` es una iteración; con
`--loop N` son N; `N>1000` o `<1` se rechaza.

## 8. Métricas y exportador

```bash
curl -s http://localhost:9871/metrics | head -40
curl -s http://localhost:9871/metrics | grep hadoop_lab_numlivedatanodes
./scripts/health/run.sh            # incluye lab.exporter y lab.metrics_prom

# una pasada a fichero (modo textfile, sin servidor):
python3 docker/exporter.py --once --targets \
  namenode=localhost:9870,resourcemanager=localhost:8088,datanode1=localhost:9864 \
  --output data/metrics/hadoop-lab.prom
```

Para el scraping y el dashboard del Prometheus/Grafana existentes:
`observability/README.md` (ambos **provistos, no aplicados**).

## 9. Persistencia, copia y restauración

Todo el estado está en `./data/` (bind mounts, no volúmenes con nombre):

```
data/namenode/       fsimage + edits (única fuente de verdad de HDFS)
data/datanode1|2/    bloques
data/yarn/nm1|nm2/   directorios locales de YARN
data/logs/           logs de los daemons
data/reports|metrics|inventory/   informes de validación e inventario
```

Verificación de que sobrevive a `down`/`up` (drill `persistence`):

```bash
docker compose exec -T client bash -lc 'hdfs dfs -put -f README.md /lab/persistence/ && hdfs dfs -cat /lab/persistence/README.md'
./scripts/lab/down.sh && ./scripts/lab/up.sh
docker compose exec -T client bash -lc 'hdfs dfs -cat /lab/persistence/README.md'   # debe devolver el fichero
```

Copia de seguridad recomendada (HDFS **detenido**, para no copiar un fsimage a
medias):

```bash
./scripts/lab/down.sh
tar -czf "backup-lab-$(date +%Y%m%d).tar.gz" data/namenode data/datanode1 data/datanode2
./scripts/lab/up.sh
```

Restauración: `./scripts/lab/reset.sh` → descomprimir el tar sobre `data/` →
`./scripts/lab/up.sh` (el `clusterID` del `VERSION` es el mismo, así que los
DataNodes vuelven a registrarle). Comprobación:
`cat data/namenode/current/VERSION | grep clusterID`.

## 10. Drills de administración

| Drill | Cómo | Qué debe pasar |
|---|---|---|
| Caída de un DataNode | `docker compose stop datanode2` | `hdfs.datanode2=FAIL`, `hdfs.datanodes.live=DEGRADED (1/2)`, `hdfs.write_read=PASS`, escritura sigue funcionando |
| Recuperación | `docker compose start datanode2` | en ≤60 s vuelve a `Live datanodes (2)` y `Under replicated blocks: 0` |
| Caída de un NodeManager | `docker compose stop nodemanager2` | `yarn.nodes=DEGRADED (1/2)`, las apps en marcha se reprograman en el NM vivo |
| Safe mode | `docker compose exec -T namenode hdfs dfsadmin -safemode enter` | escrituras fallan; `hdfs.safemode=FAIL`; salir con `-safemode leave` |
| Pérdida de datos | borrar `data/datanode1` estando parado | al subir, `hdfs fsck` reporta bloques perdidos → se practica recuperación desde `data/datanode2` o backup |
| Añadir un nodo | copia del bloque `datanode2` en `compose.yaml` como `datanode3` (puerto libre, volumen nuevo) + `docker compose up -d` | 3 DataNodes en `dfsadmin -report`; subir `dfs.replication` a 3 si se quiere |
| Reinicio total | `./scripts/lab/down.sh && ./scripts/lab/up.sh` | estado HDFS intacto (drill §9) |

## 11. Límites operativos conocidos

Documentados a propósito (no son fallos, son decisiones de alcance):

- **Sin HA**: un NameNode; su caída es un incidente mayor.
- **Sin Kerberos**: seguridad desactivada (`dfs.permissions.enabled=false`).
- **Sin cifrado en reposo ni TLS**: laboratorio local.
- **Sin NameNode Secondary / Checkpoint**: se confía en `data/namenode`
  (por eso §9 insiste en la copia antes de manipular).
- **Sin History Server de Spark, sin Hive/HBase/Kafka**: `NOT_CONFIGURED` en
  la validación, por diseño (`docs/architecture.md` §3).
- **Sin backend de logs central**: logs en ficheros (Loki/OTel inexistentes).
