# Observabilidad — integración con la infraestructura existente

Este laboratorio **no despliega** Prometheus ni Grafana: ya existen en
`gcp-architecture-lab` (puertos 9091 y 3001, ver `docs/local-inventory.md`).
Duplicarlos sería justo lo que el encargo pide evitar.

## 0. Qué hay hoy (todo dentro de este repo)

| Pieza | Cómo | Estado |
|---|---|---|
| Healthchecks Docker | `healthcheck` de cada servicio en `compose.yaml` | ✅ activo (8/8 healthy) |
| Métricas Hadoop | JMX en `/jmx` de NN, RM, DN y NM (JSON de Hadoop) | ✅ activo |
| **Exportador Prometheus** | contenedor `hl-metrics` → `http://localhost:9871/metrics` | ✅ activo |
| Métricas de validación | `data/metrics/validation.prom` (textfile) | ✅ activo |
| Logs | `./data/logs/<servicio>/` + `scripts/diagnostics/logs.sh` | ✅ activo |
| Scraping desde el Prometheus vecino | `prometheus/hadoop-scrape-job.yml` | ⛔ **provisto, no aplicado** |
| Dashboard en el Grafana vecino | `grafana/hadoop-platform.json` | ⛔ **provisto, no importado** |

**Nada que esté fuera de este directorio se aplica automáticamente**: tocar
`gcp-architecture-lab` exige modificar su repositorio y redeployar su stack.
El procedimiento exacto y su impacto están en `docs/integration.md` §2.

## 1. El exportador (por qué existe)

Hadoop no habla el formato de Prometheus: expone JSON en `:9870/jmx`,
`:8088/jmx`, `:9864|9865/jmx` y `:8042|8043/jmx`. Hadoop 3.4.3 (la imagen
usada) no trae ningún sink Prometheus.

`docker/exporter.py` (python stdlib, sin dependencias) convierte esos JSON a
formato Prometheus **bajo demanda**: cada `GET /metrics` consulta los 6
daemons en paralelo y devuelve ~560 métricas con etiqueta `component`.

```bash
curl -s http://localhost:9871/metrics | grep hadoop_lab_numlivedatanodes
# hadoop_lab_numlivedatanodes{bean="fsnamesystemstate",component="namenode",...} 2

# una sola pasada a fichero (modo textfile, sin servidor):
python3 docker/exporter.py --once --targets namenode=localhost:9870,... \
        --output data/metrics/hadoop-lab.prom
```

Si un daemon está caído, su métrica `hadoop_lab_scrape_success{component=...}`
vale `0` y aparece `hadoop_lab_scrape_error`: el endpoint sigue respondiendo
200 (degradación visible, no caída del scrape).

Familias principales: `numlivedatanodes`, `numdeaddatanodes`,
`capacitytotal/used/remaining`, `blockstotal`, `filestotal`,
`underreplicatedblocks`, `appsrunning/pending/failed`, `availablemb`,
`allocatedmb`, `containersrunning`, `memheapusedm`, `scrape_*`.

## 2. Scraping (Prometheus existente)

Añadir `observability/prometheus/hadoop-scrape-job.yml` a
`~/projects/gcp-architecture-lab/monitoring/prometheus.yml` (fichero suyo,
**no modificado aquí**) y redeployar su stack:

```yaml
- job_name: hadoop-platform-lab
  scrape_interval: 30s
  metrics_path: /metrics
  static_configs:
    - targets: ['host.docker.internal:9871']   # o <IP-de-WSL>:9871
      labels: { lab: hadoop-platform-lab }
```

Notas de conexión:

- El Prometheus vecino vive en otra red (`gcp-arch-lab_default`), por eso se
  llega por el host: `host.docker.internal` (requiere `extra_hosts:
  ["host.docker.internal:host-gateway"]` **en su compose**) o la IP de salida
  de WSL (`hostname -I | awk '{print $1}'`).
- No se abre ninguna red entre proyectos ni se conectan contenedores ajenos.

## 3. Métrica de validación (textfile)

`./scripts/validate/validate.py` escribe `data/metrics/validation.prom`:

```
hadoop_lab_check_state{check="hdfs.safemode",group="hdfs",state="PASS"} 1
hadoop_lab_validation_summary{state="FAIL"} 0
hadoop_lab_validation_duration_seconds 71.5
```

Para exponerla: un **node_exporter** con
`--collector.textfile.directory=<repo>/data/metrics` (no existe hoy →
`NOT_CONFIGURED` en la validación). Sin él, el fichero sigue siendo legible
por un humano y empaquetable con `scripts/diagnostics/collect.sh`.

## 4. Dashboards (Grafana existente)

`grafana/hadoop-platform.json` → *Dashboards → New → Import → Upload JSON*.
El JSON declara su fuente de datos como entrada (`DS_PROMETHEUS`), así que en
la pantalla de importación Grafana preguntará a qué Prometheus apuntar:
elegir la instancia existente (uid `PBFA97CFB590B2093`, nombre `Prometheus`).

Paneles: DataNodes vivos/caídos, % de capacidad HDFS, disponibilidad del
exportador, apps y contenedores YARN, capacidad HDFS, bloques/ficheros,
apps YARN y memoria de cola, heap JVM por componente.

## 5. Logs

No hay colector de logs central (Loki/OTel no existen en la máquina): los logs
son ficheros en `./data/logs/<servicio>/` (rotados a 64 MB × 10) más
`docker logs`. Ver `docs/troubleshooting.md` §1. Estado en la cadena de
validación: `integration.log_backend = NOT_CONFIGURED`.

## 6. Métricas de sistema (CPU/RAM/disco/red del host)

Las obtiene un `node_exporter` genérico si se añade al stack de
`gcp-architecture-lab`. Dentro del laboratorio:
`./scripts/lab/status.sh` (docker stats) y
`./scripts/inventory/system.sh` (CPU, memoria, disco, redes).
