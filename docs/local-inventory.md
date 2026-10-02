# Inventario local (descubrimiento no destructivo)

> Fecha de captura: 2026-10-02. Método: inspección de solo lectura
> (`uname`, `free`, `df`, `ss`, `docker ps/ls/inspect`, `kubectl get`, `curl`).
> **Ningún servicio fue detenido, eliminado o modificado.**

## 1. Sistema y recursos

| Campo | Valor |
|---|---|
| SO | Ubuntu 24.04.2 LTS (Noble) sobre WSL2 |
| Kernel | 6.18.33.2-microsoft-standard-WSL2 |
| Host | HP-15-EH3003LA, AMD Ryzen 7 7730U |
| CPU | 16 vCPU |
| RAM | 31 GiB total, ~7.5 GiB en uso, ~23 GiB disponibles |
| Swap | 8 GiB |
| Disco raíz | `/dev/sdd` 1007 G, 290 G usados, **667 G libres** |
| Docker root | `/var/lib/docker` (mismo FS, 667 G libres) |

**Conclusión:** recursos suficientes para un clúster Hadoop multiproceso con
límites explícitos de memoria.

## 2. Herramientas

| Herramienta | Estado | Versión / nota |
|---|---|---|
| Docker | ✅ | 29.6.0 (server) |
| Docker Compose (plugin) | ✅ | v5.1.4 (`docker compose`) |
| docker-compose (legado) | ✅ | 1.29.2 |
| Podman | ❌ | no instalado |
| kubectl | ✅ | presente |
| Kind | ✅ | clúster `platform-lab-control-plane` (k8s v1.31.2) |
| Helm | ❌ | no instalado |
| Terraform | ✅ | v1.8.5 |
| Git | ✅ | 2.43.0 |
| Python | ✅ | 3.12.3 |
| Java | ✅ | OpenJDK 17.0.20.1 |
| Spark (host) | ✅ | `spark-submit` 3.5.3 vía `~/.local` (PySpark) |
| Hadoop CLI (host) | ❌ | `hdfs` / `yarn` no instalados en el host |
| gh CLI | ✅ | autenticado en GitHub como `OMaciasd` |
| curl / jq / nc / ss | ✅ | presentes |

Credenciales Git disponibles localmente: `gh` (HTTPS + helper), usuario global
`Oscar Macias <omaciasnarvaez@gmail.com>`, `init.defaultbranch=main`.

## 3. Contenedores en ejecución (23 de 31)

| Contenedor | Imagen | Puerto host | Proyecto |
|---|---|---|---|
| opsauto | opsauto:latest | 3999 | opsauto |
| opsauto-evolution-* | evolution-api / pg15 / redis7 | 8082 (127.0.0.1) | opsauto |
| opsauto-waha | devlikeapro/waha | 3000 (127.0.0.1) | opsauto |
| opsauto-cloudflared | cloudflared | — | opsauto |
| job-agent-n8n | n8n 1.117.0 | 5678 | job-agent |
| job-agent-postgres | postgres 16.10 | 5432 | job-agent |
| gcp-prometheus | prom/prometheus v2.53.0 | 9091 | gcp-architecture-lab |
| gcp-grafana | grafana 11.1.0 | 3001 | gcp-architecture-lab |
| gcp-gateway | gcp-lab-gateway | 8090 | gcp-architecture-lab |
| gcp-cloudsql | postgres 15-alpine | 5434 | gcp-architecture-lab |
| gcp-dataflow-worker | gcp-lab-worker | — | gcp-architecture-lab |
| de-postgres | postgres 16-alpine | 5433 | azure-data-engineering-lab |
| de-spark-master | de-spark:3.5.3 | 7077, 18080 | azure-data-engineering-lab |
| de-spark-worker | de-spark:3.5.3 | 8081 | azure-data-engineering-lab |
| de-airflow-webserver/scheduler | de-airflow:2.10.4 | 8080 | azure-data-engineering-lab |
| de-gui | de-gui:0.1.0 | 8501 | azure-data-engineering-lab |
| portainer | portainer-ce | 8000, 9000 | portainer-clockify |
| portainer-clockify-postgres | postgres 15-alpine | 65432 | portainer-clockify |
| ai-runtime-ollama | ollama 0.12.1 | 11434 (127.0.0.1) | ai-runtime |
| platform-lab-control-plane | kindest/node v1.31.2 | 43899 (127.0.0.1) | platformops (kind) |

Contenedores detenidos (no tocados): `opsauto-persistent`, `de-airflow-init`,
`linkedin-scraper`, `job-agent-ollama`, `job-agent-n8n-supabase-test`,
`docker-api-1`, `docker-db-1`, `docker-web-1`.

## 4. Puertos en uso (host)

`3000, 3001, 3999, 43899, 5432, 5433, 5434, 5678, 65432, 7077, 8000, 8080,
8081, 8082, 8090, 8501, 9000, 9091, 11434, 18080, 18789, 45849, 64859 (tailscale)`

**Puertos verificados libres para el laboratorio:**
`8020, 8042, 8043, 8181, 9090, 9092, 9093, 9200, 9600, 9870, 9864, 9865,
9866, 19888, 4040, 10000, 10002, 3100`

## 5. Redes Docker (todas bridge, subnets no solapadas)

| Red | Subnet | Proyecto |
|---|---|---|
| bridge | 172.17.0.0/16 | default |
| kind | 172.18.0.0/16 | kind |
| docker_default | 172.19.0.0/16 | legado (data Hadoop previo) |
| job-agent_backend | 172.20.0.0/16 | job-agent |
| ai-runtime_ai_runtime | 172.21.0.0/16 | ai-runtime |
| opsauto_default | 172.23.0.0/16 | opsauto |
| data-eng-lab_default | 172.24.0.0/16 | azure-data-engineering-lab |
| opsauto_evolution | 172.25.0.0/16 | opsauto |
| portainer-clockify_opsauto_network | 172.26.0.0/16 | portainer-clockify |
| gcp-arch-lab_default | 172.27.0.0/16 | gcp-architecture-lab |

Subnets libres: `172.22.0.0/16`, `172.28.0.0/16` en adelante.

## 6. Volúmenes relevantes

`data-eng-lab_minio-data`, `data-eng-lab_postgres-data`,
`data-eng-lab_spark-logs`, `data-eng-lab_airflow-logs-volume`,
`gcp-arch-lab_grafana-data`, `gcp-arch-lab_cloudsql-data`,
`job-agent_postgres_data`, `opsauto_evolution_*`, `pp2_*` (mongo/pg/redis,
contenedores no activos).

## 7. Búsqueda dirigida de servicios

| Servicio buscado | Estado | Detalle |
|---|---|---|
| PostgreSQL | ✅ ×4 | 5432 job-agent, 5433 data-eng, 5434 gcp, 65432 portainer-clockify |
| MySQL | ❌ | no existe |
| Redis | ✅ ×1 | `opsauto_evolution_redis` (interno, sin publicar) |
| Kafka | ❌ | no existe |
| RabbitMQ | ❌ | no existe |
| Prometheus | ✅ | gcp-architecture-lab, `:9091`, scrapea `gateway` y a sí mismo |
| Grafana | ✅ | gcp-architecture-lab, `:3001`, salud `ok` |
| Loki | ❌ | no existe (solo un compose deshabilitado en job-agent) |
| OpenTelemetry | ❌ | no existe |
| MinIO / S3 | ⚠️ | imágenes `minio` + `mc` presentes y volumen `data-eng-lab_minio-data`, **sin contenedor activo** |
| OpenSearch / Elasticsearch | ❌ | no existe |
| Airflow | ✅ | data-eng-lab `:8080`, `/health` → 200 |
| Spark | ✅ ×2 | standalone data-eng-lab (`7077`/`8081`/`18080`) + PySpark 3.5.3 en el host |
| Jupyter | ❌ | no existe |
| Hive / HBase | ❌ | no existe |
| HTTP/API + reverse proxy | ✅ | gcp-gateway:8090, de-gui:8501, n8n:5678, Portainer:9000, cloudflared (túnel saliente) |
| DNS / service discovery | ✅ parcial | DNS interno de Docker + `10.255.255.254:53` (WSL) + Tailscale (443) |
| MongoDB | ⚠️ | imagen `mongo:7.0` + volumen `pp2_mongodb_data`, contenedor inactivo |
| **Hadoop (HDFS/YARN)** | ❌ | **no existe** imagen ni instalación |

### Restos de un intento Hadoop previo (no reutilizado)

`~/projects/hadoop-lab/` (no es repositorio Git) contiene
`data/namenode`, `data/datanode1`, `data/datanode2` con `fsimage`/`VERSION`
generados el 2025-10-02 por contenedores sobre la red `docker_default`
(172.19.0.0/16) que ya no existe. Algunos archivos son de otro usuario/root
(`Permission denied` al listar). Es estado huérfano de un clúster retirado:
**clasificado como AISLADO** (ver `docs/integration.md`), no se modifica ni se
mezcla con este laboratorio.

## 8. Estado de Git / GitHub

- Proveedor configurado localmente: **GitHub** vía `gh` (cuenta `OMaciasd`),
  protocolo HTTPS con credential helper.
- Proyectos vecinos apuntan a `github.com/OMaciasd/*`.
- `~/projects/hadoop-platform-lab`: creado e inicializado con rama `main`
  (no existía previamente).

## 9. Recursos del sistema en uso (referencia para dimensionar)

`docker stats`: ~6 GiB agregados entre los 23 contenedores activos
(mayores: `platform-lab-control-plane` 1.0 GiB, `de-airflow-webserver` 772 MiB,
`opsauto-waha` 749 MiB, `de-airflow-scheduler` 623 MiB). Quedan ~23 GiB libres.
