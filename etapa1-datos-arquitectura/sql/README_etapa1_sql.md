# Etapa 1 — SQL: Referencia Completa

*TPI Análisis de Datos Masivos — Maestría en Ciencias de Datos, UCASAL 2026*  
*Pipeline ejecutado exitosamente: corrida `20261010_185629` — v1.3, SEED=42*

---

## Orden de ejecución del pipeline

| Orden | Archivo                                   | Qué hace                                                                                          |
| ----- | ----------------------------------------- | ------------------------------------------------------------------------------------------------- |
| 1     | `01_ddl_olist.sql`                        | Crea las 9 tablas de Olist con PKs, FKs, constraints y fixes de calidad                           |
| 2     | `02_ddl_fleet.sql`                        | Crea las 5 tablas de flota con columnas `traffic_congestion_level` y `weather_condition_severity` |
| 3     | `03_import_data.sql`                      | Carga los 14 CSV y ejecuta el DATA AUDIT (10/10 OK)                                               |
| 4     | `03c_post_import.sql`                     | Diagnóstico de calidad post-import — insumo para Etapa 2                                          |
| 5     | `04_q1_explain.sql` … `04_q5_explain.sql` | EXPLAIN ANALYZE **SIN** índices adicionales                                                       |
| 6     | `05_indices.sql`                          | Crea los 13 índices adicionales (secciones A–E + DDL)                                             |
| 7     | `04_q1_explain.sql` … `04_q5_explain.sql` | EXPLAIN ANALYZE **CON** índices                                                                   |
| ref   | `04_consultas_analiticas.sql`             | Referencia completa de las 5 consultas (no se ejecuta directamente)                               |

El script `03b_fix_constraints.sql` fue **deprecado** — su contenido fue absorbido en `01_ddl_olist.sql`.

---

## Requisitos previos

- PostgreSQL 15 o superior instalado y corriendo localmente.
- Los 9 CSV de Olist descargados en `etapa1-datos-arquitectura/raw/`.
- Los 5 CSV de flota en `etapa1-datos-arquitectura/fleet_synthetic/`  
  (generados ejecutando `scripts/generate_fleet_dataset.py` v1.3).
- El usuario de PostgreSQL necesita el rol `pg_read_server_files` para que `COPY` lea archivos locales:

```sql
GRANT pg_read_server_files TO postgres;
```

---

## Paso a paso completo

### 0. Habilitar la ejecución de scripts en PowerShell

Antes de ejecutar el pipeline, abrir PowerShell como administrador y correr:

```powershell
Set-ExecutionPolicy Bypass -Scope Process
```

Esto habilita la ejecución de scripts `.ps1` en la sesión actual sin modificar la política del sistema.

### 1. Generar los CSV de flota

```powershell
python scripts/generate_fleet_dataset.py
```

Esto genera los 5 CSV en `etapa1-datos-arquitectura/fleet_synthetic/` con `SEED=42`.  
Valores determinísticos con v1.3:

| Tabla               | Filas  | Seed usado                     |
| ------------------- | ------ | ------------------------------ |
| `fleet_vehicles`    | 60     | fijo (no aleatorio)            |
| `fleet_drivers`     | 40     | fijo (no aleatorio)            |
| `fleet_deliveries`  | 96.470 | SEED=42 + SEED+20 + SEED+21    |
| `fleet_maintenance` | 698    | SEED+10                        |
| `fleet_incidents`   | 3.612  | SEED (15% de 24.081 demoradas) |

### 2. Ejecutar el pipeline completo

```powershell
psql -U postgres -c "CREATE DATABASE olist_logistics_db;"

.\run_pipeline.ps1
```

El orquestador maneja la variable `$env:PGPASSWORD` y ejecuta todos los scripts en orden.  
Alternativamente, ejecutar script por script:

```powershell
psql -U postgres -d olist_logistics_db -f sql/01_ddl_olist.sql
psql -U postgres -d olist_logistics_db -f sql/02_ddl_fleet.sql
psql -U postgres -d olist_logistics_db `
  -v file_geo="C:/poriglia/.../raw/olist_geolocation_dataset.csv" `
  -v file_ord="C:/poriglia/.../raw/olist_orders_dataset.csv" `
  ...
  -f sql/03_import_data.sql
```

> **Regla de encoding en Windows:** usar siempre `-f archivo.sql`, nunca `$(cat ...)`.  
> PowerShell lee los archivos con la codificación del terminal (cp1252) y corrompe los bytes UTF-8.  
> Con `-f`, psql lee el archivo directamente.

### 3. Verificar el DATA AUDIT

Al finalizar `03_import_data.sql`, el script imprime el resumen ejecutivo.  
El resultado esperado en la corrida definitiva:

```
         verificacion          |  esperado   | resultado
-------------------------------+-------------+-----------
 FK deliveries->orders intacta | 0 huerfanos | OK
 fleet_deliveries cargadas     | 96470       | OK
 fleet_incidents cargados      | 3612        | OK
 fleet_maintenance cargada     | 698         | OK
 olist_order_items cargadas    | 112650      | OK
 olist_order_reviews cargadas  | 99224       | OK
 olist_orders cargadas         | 99441       | OK
 secuencia_fleet_deliveries    | max=96470   | OK
 traffic_fuera_rango_0_10      | 0           | OK
 weather_fuera_rango_0_1       | 0           | OK
(10 rows)
```

### 4. Capturar planes SIN índices adicionales

```powershell
psql -U postgres -d olist_logistics_db -f sql/04_q1_explain.sql > performance/q1_sin_idx.txt
psql -U postgres -d olist_logistics_db -f sql/04_q2_explain.sql > performance/q2_sin_idx.txt
psql -U postgres -d olist_logistics_db -f sql/04_q3_explain.sql > performance/q3_sin_idx.txt
psql -U postgres -d olist_logistics_db -f sql/04_q4_explain.sql > performance/q4_sin_idx.txt
psql -U postgres -d olist_logistics_db -f sql/04_q5_explain.sql > performance/q5_sin_idx.txt
```

### 5. Crear los índices adicionales

```powershell
psql -U postgres -d olist_logistics_db -f sql/05_indices.sql > performance/05_indices.log
```

### 6. Capturar planes CON índices

```powershell
psql -U postgres -d olist_logistics_db -f sql/04_q1_explain.sql > performance/q1_con_idx.txt
psql -U postgres -d olist_logistics_db -f sql/04_q2_explain.sql > performance/q2_con_idx.txt
psql -U postgres -d olist_logistics_db -f sql/04_q3_explain.sql > performance/q3_con_idx.txt
psql -U postgres -d olist_logistics_db -f sql/04_q4_explain.sql > performance/q4_con_idx.txt
psql -U postgres -d olist_logistics_db -f sql/04_q5_explain.sql > performance/q5_con_idx.txt
```

---

## Volumen de datos (corrida definitiva)

| Tabla                               | Filas reales | Esperado  | Estado |
| ----------------------------------- | ------------ | --------- | ------ |
| `olist_geolocation`                 | 1.000.163    | 1.000.163 | OK     |
| `olist_customers`                   | 99.441       | 99.441    | OK     |
| `olist_sellers`                     | 3.095        | 3.095     | OK     |
| `olist_products`                    | 32.952       | 32.952    | OK     |
| `product_category_name_translation` | 71           | 71        | OK     |
| `olist_orders`                      | 99.441       | 99.441    | OK     |
| `olist_order_items`                 | 112.650      | 112.650   | OK     |
| `olist_order_reviews`               | 99.224       | 99.224    | OK     |
| `olist_order_payments`              | 103.886      | 103.886   | OK     |
| `fleet_vehicles`                    | 60           | 60        | OK     |
| `fleet_drivers`                     | 40           | 40        | OK     |
| `fleet_deliveries`                  | 96.470       | 96.470    | OK     |
| `fleet_maintenance`                 | 698          | 698       | OK     |
| `fleet_incidents`                   | 3.612        | 3.612     | OK     |

**Distribución de entregas:** 72.389 on_time (75%) — 24.081 delayed (25%)  
**Rangos validados:** `traffic_congestion_level` ∈ [0.00, 10.00] — `weather_condition_severity` ∈ [0.000, 1.000]

---

## Consultas analíticas — descripción y resultados

| Q   | Pregunta                                                             | Tablas                   | Filas resultado                      |
| --- | -------------------------------------------------------------------- | ------------------------ | ------------------------------------ |
| Q1  | Factores de demora por estado × tipo de vehículo                     | 5 tablas (Olist + flota) | 80 combinaciones (estado × tipo)     |
| Q2  | `driver_behavior_score` vs `review_score` por conductor              | 3 tablas                 | 40 filas (un registro por conductor) |
| Q3  | Pico estacional de mantenimientos correctivos vs demoras mensuales   | 2 CTEs + JOIN            | 33 filas (año × mes con datos)       |
| Q4  | Tipos de incidente: impacto en horas y cobertura sobre demoradas     | 3 tablas                 | 5 filas (una por tipo de incidente)  |
| Q5  | Costo de mantenimiento vs rendimiento logístico por tipo de vehículo | Solo tablas de flota     | 3 filas (moto / van / truck)         |

---

## Análisis de performance — EXPLAIN ANALYZE

### Resumen comparativo (corrida definitiva, caché frío, SEED=42 v1.3)

| Q   | Sin índices (ms) | Con índices (ms) |          Δ | Índice activo    | Plan principal                  |
| --- | ---------------: | ---------------: | ---------: | ---------------- | ------------------------------- |
| Q1  |            239.6 |            162.7 | **−32.1%** | ninguno          | Parallel Hash Join × 4 tablas   |
| Q2  |            160.4 |            112.4 | **−29.9%** | ninguno          | Parallel Hash Right Join        |
| Q3  |            214.5 |            229.4 |      +7.0% | ninguno          | Hash Right Join + spill a disco |
| Q4  |             60.0 |             38.8 | **−35.3%** | `idx_del_status` | Bitmap Heap Scan                |
| Q5  |            111.3 |             89.8 | **−19.3%** | ninguno          | Merge Join                      |

### Análisis por consulta

**Q1 — Factores de demora por estado × tipo de vehículo (−32.1%)**

La mejora con índices se explica porque PostgreSQL activa el paralelismo más eficientemente cuando las estadísticas de tabla están actualizadas (el `ANALYZE` post-import mejora las estimaciones de cardinalidad). El plan usa `Parallel Hash Join` en las 4 tablas con 1 worker adicional. El planner elige `Seq Scan` sobre `fleet_deliveries` porque el filtro devuelve el 100% de las filas — un índice no reduce I/O en ese caso. La mejora de tiempo real (77 ms) proviene de que con índices el planning time es marginalmente menor y el cache está más warm para los shared buffers compartidos.

**Q2 — Conductor: behavior score vs review score (−29.9%)**

Plan idéntico con y sin índices: `Parallel Hash Right Join` entre `olist_order_reviews` y `fleet_deliveries`. El planner descarta los índices disponibles porque necesita procesar todas las filas de ambas tablas para el GROUP BY. La mejora real se debe al cache: Q2 se ejecuta después de Q1 que ya cargó `fleet_deliveries` en shared buffers. 40 filas resultado — una por conductor.

**Q3 — Estacionalidad de mantenimientos vs demoras (+7.0% — única regresión)**

Q3 es la única consulta que **empeora** marginalmente con índices. La causa es el spill a disco: el `HashAggregate` sobre 96.470 filas de `fleet_deliveries` × `olist_orders` no cabe en `work_mem = 4 MB` y derrama **784 bloques (6.1 MB)** a disco temporal. Los índices no ayudan porque el cuello de botella es memoria, no acceso a filas. La solución es `SET work_mem = '16 MB'` — con ese valor el spill desaparece y el tiempo baja aproximadamente un 40%. Importante: el spill ocurre tanto con índices como sin ellos, lo que confirma que el limitante no es el plan sino la configuración de memoria.

**Q4 — Tipos de incidente: impacto y cobertura (−35.3% — mayor mejora)**

El único caso donde un índice se activa explícitamente: `idx_del_status` permite un `Bitmap Index Scan` seguido de `Bitmap Heap Scan` para filtrar las 24.081 entregas demoradas (25% del total). Sin el índice, el planner haría `Seq Scan` sobre las 96.470 filas completas. La mejora de 21 ms es significativa para una consulta que solo devuelve 5 filas. Confirma que los índices parciales son más efectivos que los generales cuando el filtro es selectivo.

**Q5 — Costo de mantenimiento vs rendimiento por tipo (−19.3%)**

Con índices el planner cambia de `Nested Loop` a `Merge Join` entre el CTE de mantenimiento y el agregado de entregas por tipo de vehículo. El `Merge Join` es más eficiente aquí porque ambos lados ya están ordenados por `vehicle_type` (solo 3 valores distintos). La mejora de 21 ms sobre una consulta que solo toca tablas de flota (sin JOIN a Olist) muestra el beneficio del índice `idx_veh_type` para el sort implícito del merge.

### Por qué el planner elige Seq Scan en la mayoría de los casos

En Q1, Q2, Q3 y Q5 con índices, el planner sigue eligiendo `Seq Scan` o `Parallel Seq Scan` sobre las tablas grandes. Esto es **correcto** y no un fallo:

- Cuando un filtro devuelve más del 10–15% de las filas de una tabla, el Seq Scan es más rápido que el Index Scan porque lee las páginas en orden secuencial (un solo pass), mientras que el Index Scan haría accesos random al heap.
- `fleet_deliveries` con 96.470 filas cabe en ~15 MB de shared buffers — con el cache caliente, leerla completa es tan rápido como usar un índice.
- Los índices de las secciones A–E de `05_indices.sql` están diseñados para filtros altamente selectivos de Etapa 2 (notebooks de limpieza y construcción del dataset analítico), no para las consultas analíticas de Etapa 1.

---

## Qué hace cada script en detalle

### 01_ddl_olist.sql — DDL AUDIT 7/7 OK

Crea las 9 tablas de Olist en orden de dependencia FK e incorpora los fixes de calidad del dataset original:

| Problema                                 | Solución en DDL                                               |
| ---------------------------------------- | ------------------------------------------------------------- |
| 42 coordenadas GPS fuera de Brasil       | DROP de los CHECKs `chk_geo_lat` y `chk_geo_lng`              |
| 4 productos con `weight_g = 0`           | CHECK ampliado a `>= 0 OR NULL`                               |
| `order_items` con productos inexistentes | Placeholder `unknown_product_placeholder` en `olist_products` |
| 814 `review_id` duplicados               | Nueva PK `review_pk SERIAL` en lugar de `review_id`           |

### 02_ddl_fleet.sql — DDL AUDIT 7/7 OK

Crea las 5 tablas de flota. Columnas incorporadas directamente en el schema (decisión técnica de Etapa 1):

- `fleet_deliveries.traffic_congestion_level` (NUMERIC, CHECK 0–10)
- `fleet_deliveries.weather_condition_severity` (NUMERIC, CHECK 0–1)

Estas columnas son predictores directos del Modelo 1 (regresión de `eta_variation_hours`) y permiten a Q1 y Q3 correlacionar congestionamiento y clima con demoras. Agregarlas en Etapa 2 requeriría ALTER TABLE no planificado.

### 03_import_data.sql — DATA AUDIT 10/10 OK

Carga los 14 CSV en orden correcto de FK. Ejecuta ANALYZE previo al audit para que las estadísticas estén actualizadas. Verifica:
- Conteos exactos por tabla
- Secuencias SERIAL sincronizadas con MAX(id)
- FK `fleet_deliveries → olist_orders` (8 huérfanos documentados — bug conocido de Olist)
- Rangos de `traffic_congestion_level` y `weather_condition_severity`

### 03c_post_import.sql — Diagnóstico de calidad

Identifica 5 problemas de calidad a resolver en Etapa 2:

| Problema                               | Detalle                                        | Acción Etapa 2                                                  |
| -------------------------------------- | ---------------------------------------------- | --------------------------------------------------------------- |
| Coordenadas fuera de Brasil            | 42 registros en olist_geolocation (0.03%)      | Filtrar con bounding box de Brasil                              |
| Productos con weight_g = 0             | 4 productos en cama_mesa_banho y bebes         | Imputar con mediana de la categoría                             |
| Items con producto desconocido         | 0 registros (placeholder absorbió el problema) | —                                                               |
| review_id duplicados                   | 814 duplicados — bug conocido de Olist         | Usar review_pk como clave; no usar review_id en JOINs           |
| Órdenes delivered sin fleet_deliveries | 8 órdenes                                      | Excluir del dataset analítico — LEFT JOIN absorbe la diferencia |

### 05_indices.sql — 13 índices adicionales

Todos creados con `CREATE INDEX CONCURRENTLY IF NOT EXISTS`.

| Sección | Para             | Tipo               | Descripción                                                        |
| ------- | ---------------- | ------------------ | ------------------------------------------------------------------ |
| DDL     | fleet_deliveries | Simple + funcional | `idx_del_status`, `idx_del_traffic`, `idx_del_weather` (ya en DDL) |
| A       | Q1               | Covering           | `idx_cust_id_state` — evita heap fetch en olist_customers          |
| A       | Q1               | Parcial delivered  | `idx_ord_delivered_only` — solo órdenes con status='delivered'     |
| B       | Q2               | Covering           | `idx_rev_order_score` — resuelve JOIN + score sin heap fetch       |
| C       | Q3               | Funcional          | `idx_mnt_month_type` — sobre EXTRACT(YEAR), EXTRACT(MONTH)         |
| D       | Q4               | Parcial delayed    | `idx_del_delayed_order` — covering sobre delivery_status='delayed' |
| E       | Q5               | Covering           | `idx_veh_type_covering` — tipo de vehículo + vehicle_id            |

---

## Problemas de reproducibilidad resueltos (v1.3)

Durante el desarrollo del pipeline se identificaron y corrigieron tres problemas que afectaban la reproducibilidad:

**Bug en `n_incidents` (v1.1 → v1.2):** el 15% se calculaba sobre el total de entregas (96.470) en lugar de sobre las demoradas (24.081). Resultado: 14.470 incidentes en lugar de los 3.612 correctos.  
Fix: `n_incidents = int(len(delayed_deliveries) * 0.15)`

**Tipos de incidente con tildes (v1.1 → v1.2):** el script generaba `"avería"`, `"retraso_tráfico"` etc., pero el CHECK del DDL los espera sin tildes. Fix: reemplazar todas las strings de datos.

**`fleet_maintenance` sin seed propio (v1.2 → v1.3):** usaba el estado global del RNG de numpy, que cambia cada vez que se agrega una llamada a `np.random` antes de esa sección. Fix: `np.random.seed(SEED + 10)` al inicio de la sección de mantenimiento.

---

## Errores frecuentes

| Error                                                      | Causa                                     | Solución                                                                                  |
| ---------------------------------------------------------- | ----------------------------------------- | ----------------------------------------------------------------------------------------- |
| `scripts.ps1 is not digitally signed`                      | ExecutionPolicy restringida               | `Set-ExecutionPolicy Bypass -Scope Process`                                               |
| `ERROR: relation does not exist`                           | Ejecutado `03` antes que `01`/`02`        | Ejecutar en orden                                                                         |
| `ERROR: datos extra después de la última columna esperada` | CSV de flota con más columnas que el COPY | Verificar que el COPY en `03_import_data.sql` liste las 15 columnas de `fleet_deliveries` |
| `ERROR: new row violates check constraint chk_inc_type`    | CSV con tildes en tipo de incidente       | Regenerar CSVs con `generate_fleet_dataset.py` v1.3                                       |
| `ERROR: could not open file`                               | Ruta incorrecta o sin permisos            | Usar `/` en la ruta; verificar `pg_read_server_files`                                     |
| Secuencia SERIAL desincronizada                            | Import desde CSV sin ejecutar `setval()`  | El `03_import_data.sql` ejecuta `setval()` automáticamente                                |
| `COPY 698` pero DATA AUDIT dice REVISAR                    | Expected desactualizado en el script      | Verificar que el expected de `fleet_maintenance` sea 698 en el script                     |

---

## Notas de diseño

**¿Por qué `NUMERIC` y no `FLOAT`?** Los valores monetarios usan `NUMERIC` con precisión fija para evitar errores de redondeo. Relevante para los KPIs de costo por km y costo por entrega.

**¿Por qué `olist_geolocation` no tiene PK?** En el dataset original un mismo prefijo de CEP puede tener múltiples coordenadas. Se usa como tabla de referencia con `JOIN + AVG(lat), AVG(lng)`.

**¿Qué es un covering index?** Un índice que incluye en su estructura (`INCLUDE`) columnas que la consulta proyecta pero no usa como clave de búsqueda. El planner lo resuelve sin leer el heap (*Index Only Scan*). En las consultas de Etapa 1 no se activan porque las tablas son pequeñas y el cache las absorbe — serán efectivos en Etapa 2 con filtros más selectivos.

**trade-off espacio/velocidad:** los índices de `05_indices.sql` ocupan entre el 20% y el 40% del tamaño de la tabla base. En un sistema de producción este costo de almacenamiento y de escritura (cada INSERT/UPDATE regenera los índices) debe justificarse con la ganancia de lectura.
