# Arquitectura — Hadoop Platform Lab

## 1. Objetivo

Laboratorio local, gratuito y reproducible para administración de una plataforma
Hadoop/Big Data (HDFS, YARN, Spark), diseñado con una mentalidad **hiperconvergente**:
reutilizar y centralizar la infraestructura que ya existe en la máquina, y crear
únicamente lo que falta.

Principio rector: **DESCUBRIR → DISEÑAR → IMPLEMENTAR → VALIDAR**
(inventario en `docs/local-inventory.md`, mapa en `docs/integration.md`).

## 2. Diagrama

```
                                ┌──────────────────────────────────────────────┐
                                │  ~/projects/hadoop-platform-lab (este repo)  │
                                │  red docker: hadoop_lab 172.28.0.0/16 (fija) │
                                │                                              │
   host (WSL2 Ubuntu 24.04)     │   ┌───────────┐        ┌──────────────────┐   │
  ┌──────────────────────┐      │   │ namenode  │◄──RPC──│ resourcemanager  │   │
  │ scripts/ (bash/py3)  │      │   │  :8020    │  8020  │     :8088        │   │
  │  inventory/ health/  │──────┼──►│  UI :9870 │        │  UI  :8088       │   │
  │  diagnostics/        │ exec │   └─────┬─────┘        └───────┬──────────┘   │
  │  validate/           │      │         │ hb/NN               │调度           │
  └──────────────────────┘      │   ┌──────▼──────┐   ┌──────────▼──────────┐   │
                                │   │ datanode1   │   │ nodemanager1        │   │
   REUTILIZADO (no modificado)  │   │ UI :9864    │   │ UI :8042  ┐         │   │
  ┌──────────────────────┐      │   │ + volumen   │   │ YARN 1.5G ├ límites │   │
  │ Prometheus :9091     │◄─scrap│   └─────────────┘   └──────────┘         │   │   │
  │ (gcp-arch-lab)       │ (*1) │   ┌─────────────┐   ┌──────────┐         │   │   │
  │ Grafana     :3001    │◄─import│  │ datanode2   │   │ nodemanager2        │   │   │
  │ Spark stdal :7077    │ (*2) │   │ UI :9865    │   │ UI :8043            │   │   │
  │ Airflow     :8080    │ (*3) │   └─────────────┘   └──────────────────────┘   │   │
  │ PostgreSQL  x4       │      │                                              │   │
  └──────────────────────┘      │   ┌──────────────────────────────────────┐    │   │
                                │   │ client (HDFS CLI + YARN CLI + Spark) │    │   │
                                │   └──────────────────────────────────────┘    │   │
                                │   ┌──────────────────────────────────────┐    │   │
                                │   │ metrics  JMX → Prometheus   :9871    │    │   │
                                │   │  lee /jmx internos, sirve /metrics   │    │   │
                                │   └──────────────────────────────────────┘    │   │
                                └──────────────────────────────────────────────┘

 (*1) job de scrape provisto en observability/prometheus/ — requiere tocar
      gcp-architecture-lab: NO ejecutado. El exportador :9871 sí forma parte
      de este stack (healthy); solo falta decirle al Prometheus vecino que lo mire.
 (*2) standalone existente NO se duplica; este laboratorio usa Spark sobre YARN.
 (*3) candidato natural para el loop periódico de validación — requiere DAG en data-eng-lab: NO ejecutado.
```

## 3. Componentes creados

| Servicio | Imagen | Rol | Puerto host | Healthcheck |
|---|---|---|---|---|
| `namenode` | `apache/hadoop:3.4.3` | NameNode (HDFS) | `9870` UI, `8020` RPC | `hdfs dfsadmin -safemode get` + `/jmx` |
| `datanode1` | `apache/hadoop:3.4.3` | DataNode | `9864` HTTP | `/jmx` + `dfsadmin -report` |
| `datanode2` | `apache/hadoop:3.4.3` | DataNode (réplica 2) | `9865`→9864 | igual |
| `resourcemanager` | `apache/hadoop:3.4.3` | YARN ResourceManager | `8088` UI | `/ws/v1/cluster/info` |
| `nodemanager1` | `apache/hadoop:3.4.3` | YARN NodeManager | `8042` | `/ws/v1/node/info` |
| `nodemanager2` | `apache/hadoop:3.4.3` | YARN NodeManager | `8043`→8042 | igual |
| `client` | build local (`Dockerfile.client`) | CLI HDFS/YARN + Spark 3.5.3 sobre YARN | — | — |
| `metrics` | build local (`Dockerfile.exporter`) | exportador JMX → Prometheus | `9871` `/metrics` | `GET /health` |

Decisiones:

- **2 DataNodes** → se puede practicar réplica=2, decommission, safe mode,
  pérdida de un nodo y recuperación.
- **2 NodeManagers** → prácticas de scheduling, node list, aislamiento de nodo,
  agotamiento de recursos.
- **Spark sobre YARN** (no un segundo Spark standalone) para no duplicar el
  clúster standalone que ya corre en `azure-data-engineering-lab`.
- Ningún componente se añade "por tamaño": no hay Hive/Kafka/Jupyter porque no
  son necesarios para los objetivos declarados (§7 del encargo).

## 4. Recursos y límites

| Servicio | memoria_reservation | memoria límite | cpus |
|---|---|---|---|
| namenode | 512M | 1G | 1 |
| datanode1/2 | 512M | 1G | 1 |
| resourcemanager | 512M | 1G | 1 |
| nodemanager1/2 | 1G | 3G | 2 |
| client | 256M | 1G | 1 |
| metrics | 32M | 64M | 0.25 |

`yarn.nodemanager.resource.memory-mb=1536`, `yarn.nodemanager.resource.vcores=4`
→ techo YARN de **3072 MB / 4 vcores** por nodo. Los contenedores NM admiten
3 GB para que el heap de YARN más los contenedores de aplicación quepan dentro
del límite: el techo efectivo de YARN lo fija `yarn-site.xml`, no el contenedor.
Uso observado del stack completo: ~2.5 GB, quedando ~20 GiB libres para el
resto de proyectos (inventario §2).

## 5. Red y puertos

- Red propia y explícita: `hadoop_lab`, subnet fija `172.28.0.0/16`
  (verificada libre frente a las 10 redes existentes, ver inventario §5).
- No se conecta a ninguna red de otro proyecto → cero riesgo de romper vecinos.
- Puertos del host verificados libres antes de asignarlos
  (`scripts/inventory/ports.sh`): 8020, 8042, 8043, 8088, 9864, 9865, 9870 y 9871
  (exportador). `LAB_PORTS` en `scripts/lib/common.sh` es la lista única que
  comparten inventario, `up.sh` y la validación.
- `8082` (ocupado por evolution-api) y `3000` (waha) se evitan explícitamente.

## 6. Persistencia

Prioridad del encargo: volúmenes Docker > filesystem local > servicios existentes.

| Dato | Mecanismo | Sobrevive a |
|---|---|---|
| fsimage/edits (NameNode) | bind `./data/namenode/` | recreate, down, reboot |
| bloques (DataNode 1/2) | bind `./data/datanode1/`, `./data/datanode2/` | idem |
| directorios locales YARN | bind `./data/yarn/nm1`, `./data/yarn/nm2` | idem |
| logs Hadoop | bind `./data/logs/<servicio>/` | auditable desde el host |
| reportes de validación | bind `./data/reports/`, `./data/metrics/` | idem |
| estado de inventario | bind `./data/inventory/` | idem |

No se usa ningún servicio cloud. `data/` está en `.gitignore` (datos locales,
no código).

## 7. Flujo de validación (loop acotado)

`scripts/validate/validate.py` recorre una cadena de comprobaciones:

`componente → dependencia → conectividad → servicio → registro → fallo puntual → siguiente`

- Estados: `PASS`, `FAIL`, `DEGRADED`, `NOT_CONFIGURED`.
- Códigos de salida: `0` sin incidencias, `1` algún `FAIL`, `2` error de uso
  (argumentos o dependencias de selección), `3` sin `FAIL` pero con `DEGRADED`.
- Cada check tiene timeout propio; el script **siempre termina** (sin `--loop`:
  1 iteración; con `--loop N --interval S`: N iteraciones, N ≤ configurable,
  nunca infinito por defecto).
- Salida: tabla por consola + `data/reports/validation-<ISO>.json` +
  `data/metrics/validation.prom` (textfile para Prometheus).
- `NOT_CONFIGURED` identifica componentes opcionales ausentes por diseño
  (Kafka, Postgres del lab, Hive…); `DEGRADED` identifica servicio vivo pero
  incompleto (1 DataNode de 2, safe mode activo, JobHistory caído…).

## 8. Observabilidad

| Capa | Mecanismo | ¿Reutiliza infra existente? |
|---|---|---|
| Health de contenedor | `healthcheck` Docker por servicio | no aplica (propio) |
| Métricas Hadoop | JMX de NN/RM/DN/NM (`/jmx`, JSON) | expuestas a cualquier scraper |
| Exportador | contenedor `hl-metrics` (`:9871/metrics`, solo stdlib de Python) | ✅ propio |
| Scraping | **Prometheus existente** (`:9091`) | ✅ provisto en `observability/` (no aplicado: toca otro repo) |
| Dashboards | **Grafana existente** (`:3001`) | ✅ dashboard provisto para importar (no aplicado) |
| Logs | ficheros en `./data/logs` + `scripts/diagnostics/logs.sh` | filesystem local compartible |
| Validación | `data/metrics/validation.prom` | legible por node_exporter textfile o Prometheus |

No se despliega un segundo Prometheus/Grafana: ya existen en
`gcp-architecture-lab`. Ver `docs/integration.md` §3 para el cambio exacto que
requiere dicha integración (no ejecutado automáticamente).

## 9. Estructura del repositorio

```
hadoop-platform-lab/
├── compose.yaml                 # stack del laboratorio (red hadoop_lab)
├── .env.example                 # variables (sin secretos reales)
├── config/hadoop/               # core-site, hdfs-site, yarn-site, log4j
├── docker/Dockerfile.client     # cliente HDFS/YARN + Spark sobre YARN
├── docker/Dockerfile.exporter   # exportador JMX → Prometheus (python:3.13-alpine)
├── docker/exporter.py           # lógica del exportador (GET /metrics, --once)
├── scripts/
│   ├── lib/common.sh            # colores, logging, timeouts, esperas
│   ├── inventory/               # system.sh docker.sh ports.sh run.sh
│   ├── health/                  # hdfs.sh yarn.sh spark.sh aux.sh run.sh
│   ├── diagnostics/             # diagnose.sh logs.sh collect.sh
│   ├── validate/validate.py     # cadena de validación con estados
│   └── lab/                     # up.sh down.sh status.sh reset.sh
├── observability/               # job de scrape Prometheus + dashboard Grafana
├── docs/                        # architecture, local-inventory, integration,
│                                # troubleshooting, operations
└── data/                        # (gitignored) logs, reportes, volúmenes host
```

## 10. Por qué no Kubernetes

Existe un clúster Kind (`platform-lab-control-plane`, k8s 1.31.2) con 2
despliegues de demostración (uno en CrashLoopBackOff, 12k reinicios). Mover
Hadoop a Kind añadiría complejidad de operadores/StatefulSets sin aportar a los
objetivos (HDFS/YARN/administración de clúster), y obligaría a compartir un
clúster ajeno. Se clasifica como **AISLADO** en `docs/integration.md`.
