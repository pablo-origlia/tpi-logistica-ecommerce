# Etapa 1 — Problema, datos y arquitectura

*TPI Análisis de Datos Masivos — Maestría en Ciencias de Datos, UCASAL 2026*

Esta etapa define el problema, construye la base de datos `olist_logistics_db` en PostgreSQL, carga y valida los datos, y ejecuta las cinco consultas analíticas con su análisis de performance (`EXPLAIN ANALYZE`, sin y con índices adicionales).

El problema, las fuentes, las preguntas analíticas y los KPIs están en `docs/propuesta_datasets_tpi.md`; la estructura de la base (campos, tipos, claves y relaciones) en `docs/diccionario_datos_kpis.xlsx`.

---

## 1. Contenido

```
etapa1-datos-arquitectura/
├── raw/                          CSV originales (Olist y Logistics and Supply Chain, de Kaggle). No se editan
├── fleet_synthetic/              5 CSV de flota + fleet_generation_log.txt (los produce scripts/generate_fleet_dataset.py)
├── scripts/
│   └── generate_fleet_dataset.py
├── sql/
│   ├── 01_ddl_olist.sql          9 tablas de Olist (claves, restricciones, índices) + verificación del esquema
│   ├── 02_ddl_fleet.sql          5 tablas de flota + verificación del esquema
│   ├── 03_import_data.sql        carga de los 14 CSV con \copy + auditoría de volúmenes y secuencias
│   ├── 03c_post_import.sql       diagnóstico de los problemas de calidad conocidos (solo lectura)
│   ├── 03d_sanidad_flota.sql     chequeos de sensatez de la flota (solo lectura)
│   ├── 04_q1_explain.sql … 04_q5_explain.sql    las 5 consultas analíticas con EXPLAIN ANALYZE
│   ├── 05_indices.sql            14 índices adicionales (compuestos, funcionales, covering y parciales)
│   └── run_pipeline.ps1          ejecuta todo en orden y mide el tiempo de cada consulta
├── docs/
│   ├── propuesta_datasets_tpi.md
│   └── diccionario_datos_kpis.xlsx
└── performance/
    ├── explain_sin_indices/      q1_sin_idx.txt … q5_sin_idx.txt
    ├── explain_con_indices/      q1_con_idx.txt … q5_con_idx.txt
    ├── resumen_tiempos.csv       primera ejecución y mediana de las repeticiones, por consulta y fase
    └── logs/                     un log por paso del pipeline
```

---

## 2. Requisitos

- PostgreSQL 15 o superior corriendo localmente (probado en PostgreSQL 18) y la base creada:
  ```powershell
  psql -U postgres -c "CREATE DATABASE olist_logistics_db;"
  ```
- Los 10 CSV de Kaggle en `raw/` (9 de Olist, incluida la traducción de categorías, y `dynamic_supply_chain_logistics_dataset.csv`).
- Python 3.10 o superior con `pandas`, `numpy` y `scipy`, para generar la flota.
- PowerShell. Si está restringida la ejecución de scripts: `Set-ExecutionPolicy Bypass -Scope Process`.

La carga usa `\copy` (del lado del cliente): `psql` lee los archivos con los permisos del usuario que ejecuta el script, por lo que el proyecto puede estar en cualquier carpeta y no hace falta ningún rol especial en el servidor.

---

## 3. Cómo ejecutar

### 3.1 Generar la flota sintética

```powershell
cd scripts
python generate_fleet_dataset.py --input ..\raw --output ..\fleet_synthetic
```

Con `SEED = 42` el resultado es determinístico: los 5 CSV y `fleet_generation_log.txt` salen siempre idénticos. El log incluye los parámetros y la validación del generador (dependencia con la realidad, marginales contra Kaggle y coherencia estructural).

### 3.2 Pipeline completo

```powershell
cd sql
.\run_pipeline.ps1
```

Pide la contraseña de PostgreSQL una sola vez y ejecuta, en este orden:

| Paso (`-Step`) | Qué ejecuta |
|---|---|
| `ddl` | `01_ddl_olist.sql` y `02_ddl_fleet.sql` (recrean las tablas) |
| `import` | `03_import_data.sql` |
| `qa` | `03c_post_import.sql` y `03d_sanidad_flota.sql` |
| `explain_sin` | Q1 a Q5 sin los índices de `05_indices.sql` |
| `indices` | `05_indices.sql` |
| `explain_con` | Q1 a Q5 con esos índices |

Cada consulta se ejecuta una primera vez, con el plan completo, y luego tres veces más para calcular la mediana. El pipeline se detiene si el DDL o la importación tienen errores. Se puede correr un solo paso (`.\run_pipeline.ps1 -Step qa`); `explain_sin` solo es “sin índices” si `05_indices.sql` todavía no se ejecutó, y `-Step all` siempre parte de tablas recién creadas.

### 3.3 Ejecución manual

```powershell
chcp 65001; $env:PGCLIENTENCODING = "UTF8"          # evita los acentos rotos en consola
psql -U postgres -d olist_logistics_db -f 01_ddl_olist.sql
psql -U postgres -d olist_logistics_db -f 02_ddl_fleet.sql
psql -U postgres -d olist_logistics_db `
     -v csv_olist="C:/ruta/etapa1-datos-arquitectura/raw" `
     -v csv_fleet="C:/ruta/etapa1-datos-arquitectura/fleet_synthetic" `
     -f 03_import_data.sql
```

Siempre con `-f archivo.sql` (no `$(cat ...)`): PowerShell lee con la codificación de la consola y corrompe los bytes UTF-8. En las rutas usar `/`, no `\`.

---

## 4. Datos cargados

| Tabla | Filas | | Tabla | Filas |
|---|---:|---|---|---:|
| `olist_geolocation` | 1.000.163 | | `fleet_vehicles` | 100 |
| `olist_customers` | 99.441 | | `fleet_drivers` | 95 |
| `olist_sellers` | 3.095 | | `fleet_deliveries` | 96.470 |
| `olist_products` | 32.952 (32.951 + 1 auxiliar) | | `fleet_maintenance` | 802 |
| `product_category_name_translation` | 71 | | `fleet_incidents` | 3.531 |
| `olist_orders` | 99.441 | | | |
| `olist_order_items` | 112.650 | | | |
| `olist_order_reviews` | 99.224 | | | |
| `olist_order_payments` | 103.886 | | | |

**Validaciones del import** (`03_import_data.sql`): los 14 conteos coinciden con lo esperado, las 5 secuencias `SERIAL` quedan sincronizadas con el máximo de su tabla, no hay entregas sin orden de Olist, y hay 8 órdenes `delivered` sin registro de flota (órdenes sin fecha de entrega: un defecto conocido de Olist). `traffic_congestion_level` está en [0, 10] y `weather_condition_severity` en [0, 1]. La flota tiene 24 motos, 53 vans y 23 trucks, y las entregas son 91,9 % a tiempo y 8,1 % demoradas.

**Diagnóstico de calidad** (`03c_post_import.sql`) — cinco problemas del dataset original que se resuelven en la Etapa 2:

| Problema | Detalle |
|---|---|
| Coordenadas fuera de Brasil | 42 de 1.000.163 en `olist_geolocation` (0,004 %) |
| Productos con peso 0 | 4 con `product_weight_g = 0` y 3 con peso nulo |
| `review_id` duplicados | 814 (98.410 únicos sobre 99.224 reseñas) |
| Órdenes `delivered` sin entrega en la flota | 8 |
| Ítems con producto desconocido | 0 (el producto auxiliar no se usa) |

**Sensatez de la flota** (`03d_sanidad_flota.sql`): 31,8 % de mantenimientos correctivos; incidentes en el 19,2 % de las entregas tardías y el 2,3 % de las puntuales; entre 498 y 2.166 entregas por conductor; los 5 vehículos sin entregas son los 5 dados de baja.

---

## 5. Decisiones de diseño

- **`olist_geolocation` sin restricción de rango geográfico.** El CSV trae coordenadas fuera de Brasil; se aceptan en la carga y se filtran en la preparación de datos.
- **`product_weight_g >= 0` o nulo.** El CSV trae pesos 0; se imputan en la preparación con la mediana de la categoría.
- **`olist_order_reviews` con clave interna `review_pk`.** `review_id` está duplicado en el dataset y no sirve como clave; se conserva como campo indexado.
- **Producto auxiliar `unknown_product_placeholder`.** Mantiene la integridad referencial si algún ítem apuntara a un producto ausente del catálogo; en la carga final ningún ítem lo usa.
- **Flota vinculada a Olist por `order_id`.** `fleet_deliveries` tiene una fila por orden entregada y hereda las fechas de `olist_orders`. Las columnas `traffic_congestion_level` y `weather_condition_severity` forman parte del esquema desde el inicio.
- **Tipos numéricos.** Los importes y las métricas usan `NUMERIC` con precisión fija para evitar errores de redondeo, relevante para los KPIs de costo por kilómetro y por entrega.
- **Índices.** El DDL crea índices simples sobre claves foráneas, estados y fechas. `05_indices.sql` agrega 14 índices compuestos, funcionales, covering (`INCLUDE`) y parciales diseñados para las consultas Q1–Q5 y para la vista analítica de la Etapa 2.

---

## 6. Consultas analíticas

| Q | Pregunta | Tablas | Filas devueltas |
|---|---|---|---:|
| Q1 | ¿Qué factores operativos se asocian a las entregas demoradas, por estado y tipo de vehículo? | `olist_orders`, `olist_customers`, `fleet_deliveries`, `fleet_vehicles`, `fleet_drivers` | 80 |
| Q2 | ¿Existe relación entre el `driver_behavior_score` y el `review_score` de cada conductor? | `fleet_drivers`, `fleet_deliveries`, `olist_order_reviews` | 95 |
| Q3 | ¿En qué meses se concentran los mantenimientos correctivos y coinciden con los picos de demora? | `fleet_maintenance`, `olist_orders`, `fleet_deliveries` | 26 |
| Q4 | ¿Qué tipos de incidente tienen más impacto y qué parte de las entregas demoradas cubren? | `fleet_incidents`, `fleet_vehicles`, `fleet_deliveries` | 5 |
| Q5 | ¿Cuál es el costo de mantenimiento frente al rendimiento por tipo de vehículo? | `fleet_maintenance`, `fleet_vehicles`, `fleet_deliveries` | 3 |

---

## 7. Análisis de performance

Cada consulta se midió con `EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL)` y `track_io_timing`, sin y con los índices de `05_indices.sql`. Los planes completos están en `performance/explain_sin_indices/` y `explain_con_indices/`, y los tiempos en `performance/resumen_tiempos.csv`.

### 7.1 Resultados

| Q | Plan principal | Índice usado | Buffers (hit + read), sin / con | Primera ejecución sin / con (ms) | Mediana de 3 repeticiones sin / con (ms) |
|---|---|---|---|---:|---:|
| Q1 | Parallel Hash Join sobre 5 tablas | ninguno | 5.227 / 5.227 | 190,6 / 201,0 | 175,2 / 208,3 |
| Q2 | Parallel Hash Right Join | ninguno | 3.804 / 3.804 | 119,3 / 179,3 | 114,6 / 156,4 |
| Q3 | Hash Right Join con *spill* a disco | ninguno | 3.713 / 3.713 + 786 temporales | 188,5 / 252,0 | 240,8 / 188,7 |
| Q4 | Bitmap Heap Scan sobre `fleet_deliveries` | `idx_del_status` (del DDL) | 1.927 / 1.927 | 26,0 / 25,2 | 25,2 / 24,9 |
| Q5 | Merge Join sobre tablas de flota | ninguno | 1.893 / 1.893 | 64,0 / 66,5 | 158,6 / 67,1 |

**Conclusión principal: los índices de `05_indices.sql` no cambian ningún plan.** Para las cinco consultas, el plan es idéntico antes y después y los buffers leídos son los mismos. Los tiempos varían entre −58 % y +37 % con planes y trabajo idénticos: es ruido de medición de la máquina, no un efecto de los índices. Por eso la métrica de comparación confiable es el trabajo realizado (plan y buffers), que es determinístico, y no el tiempo. En Q1, la primera ejecución sin índices leyó 1.494 bloques del disco (caché fría tras la carga); el total de buffers accedidos es el mismo en ambas fases.

### 7.2 Cobertura de lo pedido por el enunciado

| Aspecto | Qué se observó |
|---|---|
| **Tiempo de ejecución** | De 25 ms (Q4) a 200–250 ms (Q1 y Q3). Las consultas simples sobre pocas tablas de flota (Q4, Q5) son 3 a 8 veces más rápidas que las que cruzan Olist con la flota (Q1, Q2, Q3). El tiempo de planificación es de 10 a 45 ms |
| **Registros procesados y retornados** | Q1 lee 96.470 entregas y 99.441 clientes para devolver 80 filas; Q2 lee 99.224 reseñas y 96.470 entregas para devolver 95; Q5 lee las 96.470 entregas para devolver 3. Todas agregan un volumen grande en pocas filas, y por eso el planner prefiere recorrer las tablas completas |
| **CPU y memoria** | `EXPLAIN` no mide CPU directamente; se aproxima con los *workers* paralelos (1 en Q1, Q2 y Q5) y el tiempo de ejecución. La memoria se ve en las tablas hash (hasta 10,9 MB en Q1 y Q2) y en Q3, que excede la memoria de trabajo por defecto (`work_mem` = 4 MB) y escribe 786 bloques temporales (≈ 6 MB). Las más costosas son Q1 y Q3 |
| **Operaciones de E/S** | Todas las consultas se resuelven desde `shared_buffers` (`hit`), salvo la primera ejecución de Q1 con caché fría. Solo Q3 hace E/S temporal (786 bloques leídos y escritos) |
| **Plan estimado vs real** | El planner estima bien Q4 (7.894 filas estimadas contra 7.826 reales) y Q5, pero se equivoca en las agregaciones: Q1 estima 27 grupos y hay 80, Q2 estima 32 y hay 95, y en Q3 estima 93.544 grupos para una agregación por `EXTRACT(año, mes)` que devuelve 23, porque las estadísticas no cubren expresiones |
| **Impacto sobre otras operaciones** | Son `SELECT`: toman un bloqueo de lectura que no impide lecturas ni escrituras concurrentes. Sí consumen recursos compartidos: Q1 y Q3 recorren completa `fleet_deliveries` (15 MB), ocupan un *worker* paralelo y memoria de hash, y compiten por `shared_buffers`. Repetidas con frecuencia, afectarían a otros procesos; la Etapa 2 lo resuelve con una vista materializada |

### 7.3 Por qué el planner elige recorridos completos

- Q1, Q2, Q3 y Q5 necesitan casi todas las filas: el 97 % de las órdenes está entregado y no hay filtro selectivo. Cuando una consulta lee más del 10–15 % de una tabla, un `Seq Scan` es más barato que accesos aleatorios por índice.
- Las tablas son pequeñas (la mayor, `fleet_deliveries`, ocupa 15 MB) y caben en memoria.
- Q4 es la única que filtra con selectividad (8,1 % de entregas demoradas) y es la única que usa un índice: `idx_del_status`, que ya viene del DDL y por eso aparece igual en ambas fases.
- En Q3 el cuello de botella es la memoria, no el acceso a filas, y ningún índice lo reduce.

### 7.4 Costo de los índices

Los 14 índices de `05_indices.sql` ocupan ≈ 79 MB. Con todos los índices (los del DDL y los de `05`), `fleet_deliveries` ocupa 80 MB en total (15 MB de datos y 65 MB de índices) y `olist_orders` 59 MB (14 MB y 45 MB). Un índice solo se justifica si alguna consulta lo usa: ninguno de los 14 es usado por Q1–Q5. Los índices de la sección F (`idx_del_analytical_base` e `idx_items_order_analytical`) están pensados para la vista analítica de la Etapa 2, donde se evalúa su uso real.

---

## 8. Errores frecuentes

| Error | Causa | Solución |
|---|---|---|
| `... is not digitally signed` | Política de ejecución de PowerShell | `Set-ExecutionPolicy Bypass -Scope Process` |
| `ERROR: relation ... does not exist` | Se ejecutó un paso antes que sus dependencias | Respetar el orden `01`, `02`, `03` |
| `could not open file ... Permission denied` o `No such file` | Ruta incorrecta en `csv_olist` o `csv_fleet` | Verificar que existan los CSV; usar `/` en las rutas |
| `datos extra después de la última columna esperada` | CSV de flota con distinto número de columnas que el `\copy` | Regenerar la flota con `generate_fleet_dataset.py` |
| `violates check constraint chk_inc_type` | CSV de incidentes con tipos que no coinciden con el `CHECK` | Regenerar la flota |
| La auditoría del `03` marca `REVISAR` | Los conteos esperados del script no coinciden con los CSV | Actualizar los valores esperados en `03_import_data.sql` o regenerar la flota |
| Acentos rotos en consola o en logs | Codificación de la consola | `chcp 65001; $env:PGCLIENTENCODING = "UTF8"` (el pipeline ya lo hace) |
