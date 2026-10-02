# Hadoop Platform Lab

Laboratorio local de administración de plataforma Hadoop/Big Data
(**HDFS + YARN + Spark sobre YARN**) construido sobre la infraestructura que
**ya existe** en esta máquina, sin duplicar servicios ni romper proyectos
vecinos.

- **Ruta:** `~/projects/hadoop-platform-lab`
- **Objetivo:** practicar administración Hadoop, HDFS, YARN, Spark, monitoreo,
  troubleshooting, incident response, rendimiento y disponibilidad.
- **Principio:** *DESCUBRIR → DISEÑAR → IMPLEMENTAR → VALIDAR.*

## Estado

| Fase | Resultado |
|---|---|
| Descubrimiento | ✅ `docs/local-inventory.md` (23 contenedores activos, 10 redes, sin Hadoop previo) |
| Mapa de reutilización | ✅ `docs/integration.md` |
| Arquitectura | ✅ `docs/architecture.md` |
| Stack HDFS/YARN | ver `docs/operations.md` |
| Validación con estados | PASS / FAIL / DEGRADED / NOT_CONFIGURED |

## Inicio rápido

```bash
# 1. levantar el clúster (red propia 172.28.0.0/16, puertos verificados libres)
./scripts/lab/up.sh

# 2. validar toda la cadena de conectividad
./scripts/validate/validate.py

# 3. estado resumido
./scripts/lab/status.sh

# 4. detener (los datos persisten en volúmenes Docker)
./scripts/lab/down.sh
```

## Qué reutiliza (sin modificarlo)

| Servicio existente | Origen | Uso |
|---|---|---|
| Prometheus `:9091` | `gcp-architecture-lab` | destino de scraping (job provisto, no aplicado) |
| Grafana `:3001` | `gcp-architecture-lab` | destino de dashboard (JSON provisto, no importado) |
| Spark standalone `:7077` | `azure-data-engineering-lab` | comprobación de solo lectura; **no se duplica** |
| Airflow `:8080` | `azure-data-engineering-lab` | candidato a loop periódico (no ejecutado) |
| PostgreSQL ×4, Redis, MinIO (inactivo), Kind | varios | inventariados; hoy innecesarios |

Detalles, riesgos y los cambios exactos que implicaría cada integración:
**`docs/integration.md`**.

## Documentación

| Documento | Contenido |
|---|---|
| `docs/architecture.md` | componentes, red, puertos, límites, persistencia, validación |
| `docs/local-inventory.md` | inventario completo del equipo (no destructivo) |
| `docs/integration.md` | mapa de reutilización y estrategia de integración |
| `docs/operations.md` | cómo levantar/detener, HDFS, YARN, Spark, logs |
| `docs/troubleshooting.md` | fallos frecuentes y diagnóstico paso a paso |

## Scripts

```
scripts/inventory/     inventario de sistema, docker y puertos
scripts/health/        salud de HDFS, YARN, Spark y servicios auxiliares
scripts/diagnostics/   diagnose.sh (raíz del fallo), logs.sh, collect.sh
scripts/validate/      validate.py — cadena con estados PASS/FAIL/DEGRADED/NOT_CONFIGURED
scripts/lab/           up.sh / down.sh / status.sh / reset.sh
```

Todos son pequeños, auditables y de una sola responsabilidad; ninguno corre en
bucle infinito por defecto.

## Licencia / uso

Proyecto personal de laboratorio. Datos locales en `data/` (ignorado por Git);
ningún servicio cloud, ningún secreto versionado.
