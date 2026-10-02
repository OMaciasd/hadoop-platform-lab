# Integración — mapa de reutilización y estrategia

> Fuente: `docs/local-inventory.md`. Clasificación pedida: REUTILIZABLE /
> INTEGRABLE / CENTRALIZABLE / AISLADO / FALTANTE.
> Regla aplicada: **no se modificó, detuvo ni duplicó nada existente.** Toda
> integración que exige tocar otro repositorio está descrita, no ejecutada.

## 1. Mapa de reutilización

| Componente | Origen | Tecnología / contenedor | Puerto | Red | Volumen | Función en el lab | Clase | Riesgo | Estrategia |
|---|---|---|---|---|---|---|---|---|---|
| Prometheus | `gcp-architecture-lab` | `prom/prometheus:v2.53.0` / `gcp-prometheus` | 9091 | `gcp-arch-lab_default` 172.27/16 | bind `monitoring/prometheus.yml` | scrapear el exportador del lab (`:9871/metrics`, formato Prometheus) | **INTEGRABLE** | bajo (añadir job = redeploy de ese stack) | provisto `observability/prometheus/hadoop-scrape-job.yml`; **requiere editar `gcp-architecture-lab` → no ejecutado** |
| Grafana | `gcp-architecture-lab` | `grafana/grafana:11.1.0` / `gcp-grafana` | 3001 | 172.27/16 | volumen `gcp-arch-lab_grafana-data` | dashboards de Hadoop | **INTEGRABLE** | bajo | dashboard provisto `observability/grafana/hadoop-platform.json` para importar; **no ejecutado** |
| Spark standalone | `azure-data-engineering-lab` | `de-spark:3.5.3` master+worker | 7077, 8081, 18080 | `data-eng-lab_default` 172.24/16 | `spark-logs`, `./data` | validar su salud como servicio vecino; **no se replica** | **INTEGRABLE** (solo lectura) | nulo (GET a su UI) | healthcheck de solo lectura en `validate.py` (`spark_standalone`); el lab usa Spark **sobre YARN** en vez de un segundo standalone |
| Airflow | `azure-data-engineering-lab` | `de-airflow:2.10.4` | 8080 | 172.24/16 | `airflow-logs-volume` | candidato a ejecutar el loop periódico de validación | **INTEGRABLE** | medio (despliegue de DAG en repo ajeno) | descrito en §3; **no ejecutado**; el loop se corre desde el host/cron |
| PostgreSQL ×4 | job-agent (5432), data-eng (5433), gcp (5434), portainer-clockify (65432) | `postgres:15/16` | 4 puertos | 4 redes distintas | volúmenes propios | metadatos si algún día se añade Hive metastore | **CENTRALIZABLE** | medio (acoplamiento entre proyectos) | hoy **NOT_CONFIGURED**: el lab no necesita SQL; si Hive entra, elegir una instancia existente y crear solo una BD nueva |
| Redis | `opsauto` | `redis:7-alpine` (sin publicar) | 6379 interno | `opsauto_evolution` | `opsauto_evolution_redis` | — | **AISLADO** | alto (contenedor interno de un servicio productivo) | no se toca; el lab no necesita caché |
| MinIO (imágenes + volumen) | `azure-data-engineering-lab` (legado) | `quay.io/minio/minio`, `mc` | — | — | `data-eng-lab_minio-data` | almacenamiento S3-compatible de respaldo | **FALTANTE** (inactive) | nulo | no se arranca: HDFS es el almacenamiento del lab; queda documentado por si se necesita S3 |
| MongoDB | `pp2` (legado) | `mongo:7.0` | — | — | `pp2_mongodb_data` | — | **FALTANTE** (inactive) | nulo | fuera de alcance |
| Kind / Kubernetes | `platformops` | `kindest/node:v1.31.2` | 43899 | `kind` 172.18/16 | local-path-storage | — | **AISLADO** | alto (clúster ajeno, 1 deploy en CrashLoopBackOff) | no se usa; ver `architecture.md` §10 |
| Docker default net + datos | `~/projects/hadoop-lab` | restos NN/DN de 2025-10-02 | — | `docker_default` 172.19/16 | bind `./data` | — | **AISLADO** | medio (permisos root, estado huérfano) | **no se elimina ni se reutiliza**; clúster nuevo usa volúmenes propios |
| Puertos / subnets libres | sistema | — | 8020/8042/8043/8088/9864/9865/9870/9871 | `hadoop_lab` 172.28/16 (nueva) | — | base del lab | **REUTILIZABLE** | nulo | verificado con `ss` y `docker network ls` antes de asignar |
| Java 17, Python 3.12, curl/jq, gh | host | paquetes del sistema | — | — | — | ejecución de scripts y del cliente | **REUTILIZABLE** | nulo | uso directo, sin instalar nada |
| Imagen `apache/hadoop:3.4.3` | Docker Hub | nueva descarga | — | — | — | base del clúster | **FALTANTE** → creada | nulo | única descarga grande necesaria (ya en caché local) |

**Resumen:** 4 componentes reutilizables ya disponibles, 4 integrables
(2 ejecutados en modo solo-lectura, 2 provistos pero no aplicados por tocar
otros repositorios), 1 centralizable futuro (PostgreSQL), 3 aislados,
3 faltantes (imagen Hadoop, cliente Spark, volúmenes del lab).

## 2. Por qué NO se ejecutan las integraciones que tocan otros proyectos

El encargo prohíbe modificar repositorios ajenos sin explicarlo primero.
Las dos integraciones pendientes requerirían:

1. **Prometheus** — editar
   `~/projects/gcp-architecture-lab/monitoring/prometheus.yml` añadiendo el job
   provisto en `observability/prometheus/hadoop-scrape-job.yml`:

   ```yaml
   - job_name: hadoop-platform-lab
     scrape_interval: 30s
     metrics_path: /metrics
     static_configs:
       - targets: ['host.docker.internal:9871']   # o <IP-de-WSL>:9871
         labels: { lab: hadoop-platform-lab }
   ```

   El blanco es el **exportador del propio lab (`hl-metrics`, :9871)**, que ya
   convierte el `/jmx` JSON de Hadoop a formato Prometheus: no hace falta
   conectar redes (`docker network connect`) ni añadir `extra_hosts` dentro de
   este laboratorio. Solo el contenedor de Prometheus vecino necesita llegar a
   ese puerto por el host (`host.docker.internal` + `host-gateway`, o la IP de
   WSL).
   **Impacto:** redeploy del stack de observabilidad de ese laboratorio; si su
   config rompe, se pierde su scraping actual. **Alternativa menos
   intrusiva:** no tocarlo y leer `curl localhost:9871/metrics` a mano.

2. **Grafana** — importar un dashboard (API o UI) en la instancia de ese
   proyecto. **Impacto:** solo adición; riesgo bajo, pero sigue siendo un
   cambio en su volumen `gcp-arch-lab_grafana-data`.

3. **Airflow** — añadir un DAG que ejecute `scripts/validate/validate.py` cada
   N minutos. **Impacto:** nuevo fichero en `dags/` de ese repo + redeploy.

Si quieres que ejecute alguna de estas tres, dímelo y la haré como commit
separado en el repositorio correspondiente, dejando el laboratorio intacto.

## 3. Integración ejecutada en este laboratorio (solo lectura)

- `validate.py` consulta por HTTP la UI/API de Spark standalone (`7077`) y de
  Airflow (`/health`) para saber si los vecinos siguen vivos: son comprobaciones
  de solo lectura, sin credenciales, sin escritura.
- No se crean redes compartidas con otros proyectos: la única red nueva es
  `hadoop_lab` (172.28.0.0/16).
- Cero secretos en el repositorio: `.env.example` documenta las variables;
  `.env` está ignorado.

## 4. Secuencia de integración propuesta (futuro, por orden de valor)

| Paso | Acción | Requiere tocar | Estado |
|---|---|---|---|
| 1 | job de scrape en Prometheus | `gcp-architecture-lab` | **pendiente de tu aprobación** |
| 2 | dashboard en Grafana | `gcp-architecture-lab` | pendiente |
| 3 | DAG de validación periódica | `azure-data-engineering-lab` | pendiente |
| 4 | PostgreSQL para metastore Hive | repo del proveedor elegido | solo si se añade Hive |
