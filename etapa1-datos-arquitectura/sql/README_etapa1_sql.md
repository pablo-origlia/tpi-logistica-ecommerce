# Etapa 1 — SQL: referencia completa

## Archivos y orden de ejecución

| Orden | Archivo                              | Que hace                                                             |
| ----- | ------------------------------------ | -------------------------------------------------------------------- |
| 1     | `01_ddl_olist.sql`                   | Crea las 9 tablas de Olist con PKs, FKs y constraints               |
| 2     | `02_ddl_fleet.sql`                   | Crea las 5 tablas de flota sintetica                                 |
| 3     | `03b_fix_constraints.sql`            | Ajusta constraints ANTES del import (problemas conocidos de Olist)   |
| 4     | `03_import_data.sql`                 | Carga los CSV en la base y verifica integridad                       |
| 5     | `03c_post_import.sql`                | Diagnostico de calidad post-import — insumo para Etapa 2             |
| 6     | `04_q1_explain.sql` ... `04_q5_explain.sql` | EXPLAIN ANALYZE SIN indices — guardar en `explain_sin_indices/` |
| 7     | `05_indices.sql`                     | Crea los 12 indices compuestos, funcionales y covering               |
| 8     | `04_q1_explain.sql` ... `04_q5_explain.sql` | EXPLAIN ANALYZE CON indices — guardar en `explain_con_indices/` |
| ref   | `04_consultas_analiticas.sql`        | Referencia completa de las 5 consultas (no se ejecuta directamente)  |

**Regla de oro:** el `03b` siempre antes del `03`. Los archivos `04_qN_explain.sql`
se ejecutan dos veces — antes y despues del `05` — para comparar los planes de ejecucion.
Usar siempre `-f archivo.sql`, nunca `$(cat ...)` en PowerShell (ver seccion "Encoding").

---

## Requisitos previos

- PostgreSQL 15 o superior instalado y corriendo localmente.
- Los 9 CSV de Olist descargados en `etapa1-datos-arquitectura/raw/`.
- Los 5 CSV de flota en `etapa1-datos-arquitectura/fleet_synthetic/`
  (generados ejecutando `scripts/generate_fleet_dataset.py`).
- El usuario de PostgreSQL necesita el rol `pg_read_server_files`
  para que `COPY` pueda leer archivos del sistema de archivos local.

Para otorgar el permiso si no existe:
```sql
GRANT pg_read_server_files TO postgres;
```

---

## Paso a paso completo

### 1. Crear la base de datos

```bash
psql -U postgres -c "CREATE DATABASE olist_logistics_db;"
```

### 2. Crear las tablas

```bash
psql -U postgres -d olist_logistics_db -f 01_ddl_olist.sql
psql -U postgres -d olist_logistics_db -f 02_ddl_fleet.sql
```

Verificar que la salida no muestre ningun `ERROR` antes de continuar.
Si algo falla, el error más común es de orden de FK — revisar la sección de errores frecuentes.

### 3. Cargar los datos

Ajustar las rutas al directorio real del equipo (usar `/` aunque sea Windows):

```bash
psql -U postgres -d olist_logistics_db \
  -v csv_olist="C:/poriglia/tpi-logistica-ecommerce/etapa1-datos-arquitectura/raw" \
  -v csv_fleet="C:/poriglia/tpi-logistica-ecommerce/etapa1-datos-arquitectura/fleet_synthetic" \
  -f 03_import_data.sql
```

Al finalizar, el script ejecuta automáticamente dos verificaciones:
- **Filas por tabla** — comparar contra la tabla de volumen esperado abajo.
- **Ordenes delivered sin entrega en flota** — debe ser exactamente `0`.

#### Volumen esperado tras el import

| Tabla                               | Filas aprox.        |
| ----------------------------------- | ------------------- |
| `olist_geolocation`                 | 1.000.163           |
| `olist_customers`                   | 99.441              |
| `olist_sellers`                     | 3.095               |
| `olist_products`                    | 32.951              |
| `product_category_name_translation` | 71                  |
| `olist_orders`                      | 99.441              |
| `olist_order_items`                 | 112.650             |
| `olist_order_reviews`               | 99.224              |
| `olist_order_payments`              | 103.886             |
| `fleet_vehicles`                    | 60                  |
| `fleet_drivers`                     | 40                  |
| `fleet_deliveries`                  | ~96.000             |
| `fleet_maintenance`                 | ~720                |
| `fleet_incidents`                   | ~variable (~14.000) |

### 4. Capturar planes de ejecucion SIN indices adicionales

Las consultas del `04` deben correrse con `EXPLAIN ANALYZE` usando `-f archivo`,
nunca con `$(cat ...)` en PowerShell (ver seccion "Encoding en Windows" mas abajo).

Cada consulta tiene su propio archivo listo en la carpeta `sql/`:

| Archivo           | Consulta | Pregunta                                              |
| ----------------- | -------- | ----------------------------------------------------- |
| `04_q1_explain.sql` | Q1     | Factores de demora por estado y tipo de vehiculo      |
| `04_q2_explain.sql` | Q2     | behavior_score vs review_score por conductor          |
| `04_q3_explain.sql` | Q3     | Pico estacional de mantenimientos vs demoras          |
| `04_q4_explain.sql` | Q4     | Tipos de incidente: impacto y cobertura               |
| `04_q5_explain.sql` | Q5     | Costo de mantenimiento vs rendimiento por tipo        |

Ejecutar cada uno y redirigir la salida:

```powershell
psql -U postgres -d olist_logistics_db -f 04_q1_explain.sql `
  > ..\performance\explain_sin_indices\q1_sin_idx.txt

psql -U postgres -d olist_logistics_db -f 04_q2_explain.sql `
  > ..\performance\explain_sin_indices\q2_sin_idx.txt

psql -U postgres -d olist_logistics_db -f 04_q3_explain.sql `
  > ..\performance\explain_sin_indices\q3_sin_idx.txt

psql -U postgres -d olist_logistics_db -f 04_q4_explain.sql `
  > ..\performance\explain_sin_indices\q4_sin_idx.txt

psql -U postgres -d olist_logistics_db -f 04_q5_explain.sql `
  > ..\performance\explain_sin_indices\q5_sin_idx.txt
```

Campos a registrar en la tabla comparativa (ver al final de `04_consultas_analiticas.sql`):
- Tiempo de ejecucion (ms) — campo `Actual Time` en el plan
- Filas leidas vs retornadas — campos `Rows Removed` y `actual rows`
- Operacion principal — `Seq Scan`, `Index Scan`, `Hash Join`, `Nested Loop`
- Indice utilizado (si aplica) — campo `Index Name`

### 5. Crear los indices adicionales

```powershell
psql -U postgres -d olist_logistics_db -f 05_indices.sql `
  > ..\performance\05_indices.log
```

Al finalizar, el script imprime el listado completo de indices con su tamano en disco.
Guardar esa salida — va a la presentacion para mostrar el trade-off espacio/velocidad.

### 6. Capturar planes de ejecucion CON indices

Repetir exactamente los mismos comandos del paso 4, cambiando la carpeta de salida:

```powershell
psql -U postgres -d olist_logistics_db -f 04_q1_explain.sql `
  > ..\performance\explain_con_indices\q1_con_idx.txt

psql -U postgres -d olist_logistics_db -f 04_q2_explain.sql `
  > ..\performance\explain_con_indices\q2_con_idx.txt

psql -U postgres -d olist_logistics_db -f 04_q3_explain.sql `
  > ..\performance\explain_con_indices\q3_con_idx.txt

psql -U postgres -d olist_logistics_db -f 04_q4_explain.sql `
  > ..\performance\explain_con_indices\q4_con_idx.txt

psql -U postgres -d olist_logistics_db -f 04_q5_explain.sql `
  > ..\performance\explain_con_indices\q5_con_idx.txt
```

Completar la tabla comparativa del `04_consultas_analiticas.sql` con ambas mediciones.

---

## Que hace cada script en detalle

### 01_ddl_olist.sql — 9 tablas, 19 indices base

Crea las tablas de Olist en orden de dependencia de FK:
`olist_geolocation` → `olist_customers` → `olist_sellers` → `olist_products` →
`olist_orders` → `olist_order_items` → `olist_order_reviews` → `olist_order_payments`.

Cada tabla incluye `CHECK` constraints con los dominios reales del dataset
(27 estados de Brasil, valores validos de `order_status`, rango de `review_score`).
Esto permite detectar errores de importación inmediatamente.

### 02_ddl_fleet.sql — 5 tablas, 18 indices base

Crea las tablas de flota en orden de dependencia:
`fleet_vehicles` → `fleet_drivers` → `fleet_deliveries` → `fleet_maintenance` → `fleet_incidents`.

**Correcciones aplicadas respecto al script de generación original:**
- `fleet_incidents.type`: los valores en el CSV usan tildes
  (`'averia'`, `'retraso_trafico'`, `'condicion_climatica'`).
  El `CHECK` constraint refleja esos valores exactos.
- `fleet_drivers.license_type`: el script original genera `'E'` para trucks
  (`license_map = {"truck": "E"}`). El DDL acepta `'E'` y `'C'`,
  con una nota que indica que `'C'` aplica desde la v1.1 del script en adelante.

### 03_import_data.sql — carga en orden + verificación

Usa `COPY ... FROM` con las variables psql `:csv_olist` y `:csv_fleet`
para que cada integrante del grupo ejecute el script sin modificarlo.

Despues de cada tabla de flota ejecuta `setval()` para resetear la secuencia
`SERIAL` al máximo ya cargado, necesario porque los IDs vienen del CSV generado por Python
y no desde la secuencia de PostgreSQL.

La verificación final comprueba la integridad referencial clave:
que no haya ninguna orden `delivered` de Olist sin su registro en `fleet_deliveries`.

### Encoding en Windows — por que usar -f y no $(cat ...)

**Error que aparece:** `ERROR: secuencia de bytes no valida para codificacion UTF8: 0x97`

**Causa:** En PowerShell, la sustitucion `$(cat archivo.sql)` lee el archivo
con la codificacion del terminal (cp1252 o cp850), no como UTF-8. Los bytes
multi-byte de caracteres Unicode se corrompen antes de llegar a psql.

**Regla:** usar siempre `-f archivo.sql`. El `-f` le pasa el path directamente
a psql, que lo lee con su propia logica de encoding — funciona sin importar
la configuracion del terminal.

```powershell
# CORRECTO
psql -U postgres -d olist_logistics_db -f 04_q1_explain.sql

# INCORRECTO en Windows
psql -U postgres -d olist_logistics_db -c "$(cat 04_q1.sql)"
```

---

### 04_consultas_analiticas.sql — 5 consultas analíticas

| Consulta | Pregunta                                                    | Tablas involucradas       | Resultado                            |
| -------- | ----------------------------------------------------------- | ------------------------- | ------------------------------------ |
| Q1       | Factores de demora por estado y tipo de vehículo            | 5 tablas (Olist + flota)  | 1 fila por (estado × tipo\_vehículo) |
| Q2       | Relación behavior\_score ↔ review\_score por conductor      | 3 tablas                  | 1 fila por conductor (40 filas)      |
| Q3       | Pico estacional de mantenimientos correctivos vs. demoras   | 2 CTEs independientes     | 1 fila por (ano × mes)               |
| Q4       | Tipos de incidente: impacto en horas y cobertura            | 2 tablas + CROSS JOIN CTE | 5 filas (una por tipo)               |
| Q5       | Costo de mantenimiento vs. rendimiento por tipo de vehículo | Solo tablas de flota      | 3 filas (moto / van / truck)         |

Cada consulta usa CTEs nombradas para facilitar la explicacion en la presentacion.
Q5 es completamente interna a la flota, util para comparar su tiempo de ejecucion
contra Q1 (que cruza Olist) y demostrar el costo de los JOINs entre fuentes.

**Archivos de EXPLAIN por consulta** (carpeta `sql/`):

Cada archivo `04_qN_explain.sql` contiene exactamente la misma consulta del `04`
pero con `EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)` antepuesto. Son 100% ASCII puro
para evitar errores de encoding en Windows. Ejecutar siempre con `-f`.

| Archivo               | Tablas principales                                      | Filas resultado esperado          |
| --------------------- | ------------------------------------------------------- | --------------------------------- |
| `04_q1_explain.sql`   | olist_orders, olist_customers, fleet_deliveries, fleet_vehicles, fleet_drivers | 1 por (estado x tipo_vehiculo) |
| `04_q2_explain.sql`   | fleet_deliveries, fleet_drivers, olist_order_reviews    | 1 por conductor (~40 filas)       |
| `04_q3_explain.sql`   | fleet_maintenance, fleet_deliveries, olist_orders       | 1 por (ano x mes) — 36 filas      |
| `04_q4_explain.sql`   | fleet_incidents, fleet_deliveries, fleet_vehicles       | 5 filas (una por tipo)            |
| `04_q5_explain.sql`   | fleet_maintenance, fleet_vehicles, fleet_deliveries     | 3 filas (moto / van / truck)      |

### 05_indices.sql — 12 indices adicionales en 6 secciones

Todos los indices nuevos usan `CREATE INDEX CONCURRENTLY IF NOT EXISTS`,
lo que permite crearlos sin bloquear la base si hubiera consultas corriendo en paralelo.

| Seccion       | Para que consulta | Tipo de indice             | Beneficio esperado                                            |
| ------------- | ----------------- | -------------------------- | ------------------------------------------------------------- |
| A (3 indices) | Q1                | Covering + compuesto       | Elimina Seq Scan en olist\_orders y fleet\_deliveries         |
| B (2 indices) | Q2                | Covering                   | Evita heap fetch en fleet\_deliveries y olist\_order\_reviews |
| C (2 indices) | Q3                | Funcional sobre EXTRACT    | Permite Index Scan en GROUP BY temporal                       |
| D (2 indices) | Q4                | Covering + parcial delayed | Reduce filas leídas en fleet\_incidents                       |
| E (2 indices) | Q5                | Covering                   | Resuelve aggregates sin heap fetch                            |
| F (2 indices) | Etapa 2           | Covering anticipado        | Agiliza la generación del dataset analítico                   |

**Tres indices destacados para la presentación:**

`idx_ord_status_covering` — indice parcial `WHERE order_status = 'delivered'` con `INCLUDE`.
Solo cubre el 97% de las filas que se consultan en análisis. Mas pequeño, más rápido,
y demuestra diseño deliberado de indices.

`idx_mnt_year_month_type` — indice funcional sobre `EXTRACT(YEAR FROM date)`.
PostgreSQL puede usarlo solo si la expresión del `WHERE`/`GROUP BY` es identica.
Buen caso para mostrar cuando los indices funcionales aplican (y cuando no).

`idx_del_delayed_order` — indice parcial `WHERE delivery_status = 'delayed'`.
Cubre ~40% de las filas de `fleet_deliveries`. Mas selectivo que el indice general
`idx_del_order`, y es el que usa la CTE de cobertura en Q4.

---

## Diccionario de datos

El archivo `diccionario_datos_v1.xlsx` documenta las 14 tablas del proyecto en 4 hojas:

| Hoja            | Contenido                                                         |
| --------------- | ----------------------------------------------------------------- |
| **Portada**     | Descripción del proyecto, fuentes y clave de vinculación          |
| **Diccionario** | Todas las tablas con campos, tipos, PK/FK, NOT NULL y descripción |
| **KPIs**        | 14 indicadores con formula, fuente, unidad y tipo                 |
| **Relaciones**  | Foreign keys entre tablas con cardinalidad y notas                |

Colocar en: `etapa1-datos-arquitectura/docs/diccionario_datos_v1.xlsx`

---

## Errores frecuentes

| Error                                                   | Causa probable                             | Solucion                                                  |
| ------------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------- |
| `ERROR: relation does not exist`                        | Se ejecuto `03` antes que `01`/`02`        | Ejecutar en orden                                         |
| `ERROR: invalid input syntax for type numeric`          | CSV con valores vacíos no manejados        | Verificar que el `COPY` use `NULL ''`                     |
| `ERROR: could not open file`                            | Ruta incorrecta o sin permisos             | Usar `/` en la ruta; verificar `pg_read_server_files`     |
| `ERROR: insert or update on table violates foreign key` | Orden de carga incorrecto                  | Respetar el orden del `03_import_data.sql`                |
| `ERROR: new row violates check constraint chk_inc_type` | Incidente con tilde no reconocida          | Verificar encoding UTF-8 en el `COPY` (`ENCODING 'UTF8'`) |
| `ERROR: duplicate key value violates unique constraint` | `05` ejecutado dos veces                   | Los indices usan `IF NOT EXISTS` — no debería ocurrir     |
| Secuencia SERIAL desincronizada                         | Insertar filas manuales después del import | Ejecutar `SELECT setval(...)` manualmente                 |

---

## Notas de diseno

**¿Por que `NUMERIC` y no `FLOAT`?**
Los valores monetarios (`freight_value`, `cost_brl`, `payment_value`) usan `NUMERIC`
con precision fija para evitar errores de redondeo de punto flotante.
Relevante para los KPIs financieros (costo por km, costo por entrega).

**¿Por que `olist_geolocation` no tiene PK?**
En el dataset original un mismo prefijo de CEP puede tener multiples coordenadas medidas.
No hay clave natural unica — se usa como tabla de referencia con JOIN + `AVG(lat)`, `AVG(lng)`.

**¿Que es un covering index y por que importa?**
Un covering index incluye en su estructura (`INCLUDE`) columnas que la consulta necesita
proyectar pero no usar como clave de busqueda. El planner resuelve la consulta entera
desde el indice sin leer el heap de la tabla (*index-only scan*).
Esto aparece en el `EXPLAIN ANALYZE` como `Index Only Scan` en lugar de `Index Scan`.

**¿Por que `CREATE INDEX CONCURRENTLY`?**
Permite crear indices sin adquirir un lock exclusivo sobre la tabla.
En producción es esencial para no bloquear operaciones concurrentes.
En desarrollo (base vacía o sin trafico) no hace diferencia, pero es buena practica documentarla.

**Trade-off espacio / velocidad de los indices:**
La consulta final de `05_indices.sql` muestra el tamaño de cada indice en disco.
Típicamente los indices ocupan entre el 20% y el 40% del tamaño de la tabla.
Mostrar esta relación en la presentación demuestra comprensión del costo real
de mantener indices en un sistema de producción.
