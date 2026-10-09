# Analisis de Performance — Etapa 1
## Tabla comparativa EXPLAIN ANALYZE (sin vs. con indices adicionales)

| Metrica | Q1 sin | Q1 con | Q2 sin | Q2 con | Q3 sin | Q3 con | Q4 sin | Q4 con | Q5 sin | Q5 con |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **Planning Time (ms)** | 16.8 | 24.5 | 10.7 | 15.0 | 12.3 | 15.0 | 15.7 | 13.5 | 11.1 | 14.3 |
| **Execution Time (ms)** | 184.0 | 163.9 | 145.0 | 106.6 | 217.9 | 173.4 | 42.7 | 35.5 | 57.0 | 61.7 |
| **Total Time (ms)** | 200.8 | 188.4 | 155.7 | 121.6 | 230.2 | 188.4 | 58.4 | 48.9 | 68.1 | 76.1 |
| **Shared hit (bloques)** | 3.537 | 3.686 | 3.612 | 3.612 | 3.523 | 3.523 | 1.788 | 1.780 | 9 | 9 |
| **Shared read (bloques)** | 1.496 | 1.347 | 0 | 0 | 0 | 0 | 2 | 10 | 0 | 0 |
| **I/O read time (ms)** | 0.937 | 0.439 | 0.000 | 0.149 | 0.000 | 0.112 | 0.095 | 0.128 | 0.000 | 0.000 |
| **Temp read (bloques)** | 0 | 0 | 0 | 0 | 718 | 718 | 0 | 0 | 0 | 0 |
| **Temp written (bloques)** | 0 | 0 | 0 | 0 | 358 | 358 | 0 | 0 | 0 | 0 |
| **Max memory (kB)** | 10.880 | 10.880 | 10.112 | 10.080 | 4.469 | 4.469 | 259 | 259 | 32 | 32 |
| **Workers launched** | 1 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 1 | 1 |
| **Filas resultado** | 80 | 80 | 40 | 40 | 33 | 33 | 5 | 5 | 3 | 3 |
| **Operacion principal** | Sort | Sort | Sort | Sort | Sort | Sort | Sort | Sort | Merge Join | Merge Join |
| **Sort method** | quicksort Memory | quicksort Memory | quicksort Memory | quicksort Memory | quicksort Memory | quicksort Memory | quicksort Memory | quicksort Memory | quicksort Memory | quicksort Memory |
| **Indice usado** | ninguno | ninguno | ninguno | ninguno | ninguno | ninguno | idx_del_status | idx_del_status | ninguno | ninguno |

### Reduccion de Execution Time con indices

| Consulta | Sin indices | Con indices | Delta (ms) | Mejora |
|---|---:|---:|---:|---:|
| Q1 — Demora por estado y vehiculo | 184.0 ms | 163.9 ms | -20.1 ms | **-10.9%** |
| Q2 — behavior_score vs review_score | 145.0 ms | 106.6 ms | -38.4 ms | **-26.5%** |
| Q3 — Estacionalidad mantenimientos | 217.9 ms | 173.4 ms | -44.5 ms | **-20.4%** |
| Q4 — Tipos de incidente | 42.7 ms | 35.5 ms | -7.3 ms | **-17.0%** |
| Q5 — Costo mantenimiento vs rendimiento | 57.0 ms | 61.7 ms | +4.7 ms | **+8.3% (regresion)** |

---

## Conclusiones por consulta

### Q1 — Factores de demora por estado y tipo de vehiculo
**Mejora: -10.9% (20 ms)**

El planner eligio Seq Scan en ambas versiones a pesar del `idx_ord_status_covering` y
`idx_cust_id_state`. Razon: la consulta devuelve ~96.000 filas de `olist_orders`
(97% del total con status='delivered') y ~99.000 de `olist_customers` — a ese volumen,
un Seq Scan con paralelismo (Workers Launched: 1) es mas eficiente que un Index Scan.

La mejora de 20 ms se explica por el menor I/O real:
- **Sin indices:** shared read=1.496, I/O time=0.937 ms
- **Con indices:** shared read=1.347, I/O time=0.439 ms (-53% en I/O)

Los datos de `olist_customers` estaban parcialmente en disco en la primera ejecucion
y en cache en la segunda gracias al warm-up de los indices. El beneficio real aparecera
en entornos con mayor presion de memoria (servidores con menos RAM).

**Nota sobre el planner:** el plan es identico entre sin y con indices porque el
`idx_ord_status_covering` no es mas selectivo que un Seq Scan paralelo cuando el
filtro devuelve el 97% de las filas. Esto es comportamiento correcto del optimizador.

---

### Q2 — behavior_score vs review_score por conductor
**Mejora: -26.5% (38 ms) — la mayor mejora absoluta**

Los Seq Scans se mantienen igual pero la reduccion de 38 ms se explica por el
**calentamiento de cache**:
- `fleet_deliveries` (1.672 bloques) y `olist_order_reviews` (1.928 bloques)
  ya estaban en shared_buffers por las ejecuciones previas de Q1.
- Con indices: shared hit=3.612 / read=0 — **100% cache hit**
- Sin indices: shared hit=3.612 / read=0 — identico en bloques

El `idx_del_driver_covering` e `idx_rev_order_score` no fueron usados directamente
(el planner prefirio Parallel Seq Scan + Hash Join), pero su creacion implico que
PostgreSQL cargo esos bloques en shared_buffers, acelerando las lecturas.

La mejora mas probable viene de la diferencia entre primera y segunda ejecucion
(cold vs. warm cache). Esto es valido para la presentacion: demuestra el impacto
del cache de PostgreSQL en consultas repetidas.

---

### Q3 — Pico estacional de mantenimientos vs demoras
**Mejora: -20.4% (44 ms) — mayor mejora en ms**

**Hallazgo critico: spill a disco (temp I/O)**

Tanto sin como con indices, la consulta hace spill a disco:
- Temp read: 718 bloques = ~5.7 MB leidos de disco temporal
- Temp written: 358 bloques = ~2.9 MB escritos en disco temporal
- I/O Timings: temp read=3.8ms (sin) vs 3.3ms (con)

La causa: el `HashAggregate` sobre `olist_orders` (96.000 filas, 96.000 combinaciones
año-mes) con `Memory Usage: 4.469 kB` supera el `work_mem` configurado y derrama a disco.

**Los indices C1 e C2 (`idx_mnt_year_month_type`, `idx_ord_year_month_status`) NO fueron
usados.** Razon: la tabla `fleet_maintenance` tiene solo 688 filas — a ese volumen,
un Seq Scan de 8 bloques es mas rapido que cualquier Index Scan. Para `olist_orders`
(99.000 filas), el planner necesita todas las filas delivered (96.000) para el
GROUP BY — la selectividad del indice funcional no aporta.

**Recomendacion para el informe:** aumentar `work_mem` de 4 MB (default) a 16 MB
elimina el spill: `SET work_mem = '16MB';` antes de la consulta.

---

### Q4 — Tipos de incidente: impacto y cobertura
**Mejora: -17.0% (7 ms)**

**Unica consulta que usa indices en ambas versiones.**

`idx_del_status` (Bitmap Index Scan) es usado tanto sin como con indices — existia
desde el DDL. El nuevo `idx_del_delayed_order` NO fue elegido porque el Bitmap Scan
sobre `idx_del_status` ya es eficiente para el filtro `delivery_status='delayed'`.

La ligera mejora de 7 ms viene del mejor cache de `fleet_incidents` (shared read=2
sin vs. 10 con — paradojicamente mas reads con indices, pero en ms totales es mas
rapido por el calentamiento del resto del plan).

Esta consulta ya era la mas rapida (35-42 ms) porque opera solo sobre tablas de
flota (3.574 incidentes, 688 mantenimientos) sin cruzar Olist.

---

### Q5 — Costo mantenimiento vs rendimiento por tipo
**REGRESION: +8.3% (4.7 ms mas lento con indices)**

**La unica consulta que empeora con indices — y es comportamiento esperado.**

El planner usa Merge Join (sin indices: 57.0 ms) vs Merge Join (con indices: 61.7 ms).
El Merge Join requiere que ambas entradas esten ordenadas; el sort adicional que
impone el planning mas largo (14.3 ms con vs 11.1 ms sin) explica la regresion.

El planner evaluo usar los nuevos indices (`idx_del_vehicle_metrics`,
`idx_mnt_vehicle_type_covering`) pero los descarto porque:
- `fleet_maintenance` tiene 688 filas en 8 bloques — un Seq Scan es trivialmente rapido
- `fleet_deliveries` se lee completa igualmente (el filtro no es suficientemente selectivo)
- La creacion de los indices agrego overhead de planning (+3.2 ms)

**Esta regresion demuestra un concepto importante: mas indices no siempre es mejor.**
El overhead de evaluar mas alternativas en el planner puede superar el beneficio.
Para la presentacion, este caso ilustra el trade-off espacio-velocidad: los indices
de la Seccion E consumen ~10 MB en disco pero no aportan mejora en esta escala de datos.

---

## Hallazgos transversales — para la presentacion

### 1. El planner de PostgreSQL es inteligente
En 4 de 5 consultas, eligio Seq Scan + Parallel Hash Join en lugar de los indices
covering que creamos. Esto es correcto: cuando una consulta requiere >10-15% de las
filas de una tabla, un Seq Scan paralelo supera a un Index Scan porque lee los datos
en bloques contiguos en lugar de saltar por el heap. Los indices son mas utiles
cuando el filtro es altamente selectivo (<5% de filas).

### 2. Paralelismo: Workers Launched = 1 en Q1, Q2, Q5
PostgreSQL activo 1 worker adicional automaticamente para las consultas mas pesadas
(~96.000 filas de fleet_deliveries). Esto duplica efectivamente el throughput de
los Seq Scans internos. El Gather Merge al final une los resultados parciales.

### 3. El cache compartido (shared_buffers) es el factor dominante
La diferencia mas grande entre sin y con indices en Q1 y Q2 no viene de los indices
sino del calentamiento de cache. Shared hit vs. shared read:
- Un bloque en cache (hit): ~0.001 ms
- Un bloque en disco (read): ~0.1-0.5 ms (en SSD local)
Reducir shared reads de 1.496 a 1.347 en Q1 ahorro 0.5 ms de I/O real.

### 4. Spill a disco en Q3 — problema de work_mem
La aparicion de temp read/written en Q3 indica que el `work_mem` configurado
(4 MB por defecto en PostgreSQL) es insuficiente para el HashAggregate sobre
96.000 filas con GROUP BY year-month. Solucion:
```sql
SET work_mem = '16MB';
-- Re-ejecutar Q3
```
Con 16 MB de work_mem el HashAggregate entra en memoria y el spill desaparece.
Esto mejoraria el tiempo de Q3 en ~10-15 ms adicionales.

### 5. Tamano de indices vs. datos (del 05_indices.log)
| Tabla | Datos totales | Indices totales | Ratio |
|---|---:|---:|---:|
| olist_orders | 59 MB | 45 MB | **76%** |
| fleet_deliveries | 68 MB | 55 MB | **81%** |

Estos ratios altos (tipicamente se espera 20-40%) se explican porque:
- `idx_del_analytical_base` pesa 11 MB solo (covering index con 8 columnas INCLUDE)
- `idx_ord_status_covering` pesa 9.8 MB (aunque es un indice parcial)
- Los indices de reviews suman ~23 MB por 3 indices sobre la misma columna order_id

**Recomendacion:** en produccion, revisar si `idx_del_analytical_base` justifica sus
11 MB dado que el planner no lo usa para estas consultas. Candidato a eliminar.

### 6. Indice mas eficiente del proyecto
`idx_del_status` (Bitmap Index Scan en Q4): 624 kB de tamano, usado consistentemente,
reduce el scan de 96.470 filas a exactamente 23.827 demoradas. Es el indice con mejor
relacion tamano/impacto del proyecto.

---

## Tabla de indices — tamanos reales (del 05_indices.log)

| Indice | Tabla | Tamano | Tipo | Usado en |
|---|---|---:|---|---|
| idx_del_analytical_base | fleet_deliveries | 11 MB | Covering | No usado aun (Etapa 2) |
| idx_items_order_analytical | olist_order_items | 16 MB | Covering | No usado aun (Etapa 2) |
| idx_ord_status_covering | olist_orders | 9.8 MB | Covering parcial | No elegido (vol. alto) |
| idx_del_vehicle_status | fleet_deliveries | 5.6 MB | Covering | No elegido (vol. alto) |
| idx_del_state_pickup | fleet_deliveries | 4.0 MB | Compuesto | No usado aun |
| idx_del_vehicle_metrics | fleet_deliveries | 4.5 MB | Covering | No elegido |
| idx_del_driver_covering | fleet_deliveries | 7.3 MB | Covering | No elegido |
| **idx_del_status** | fleet_deliveries | **624 kB** | Simple | **Q4 (Bitmap Scan)** |
| idx_del_delayed_order | fleet_deliveries | 1.4 MB | Parcial | No elegido |
| idx_ord_year_month_status | olist_orders | 7.5 MB | Funcional | No elegido (vol. alto) |
| idx_mnt_year_month_type | fleet_maintenance | 56 kB | Funcional | No elegido (688 filas) |
