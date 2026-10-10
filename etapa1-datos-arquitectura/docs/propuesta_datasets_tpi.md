# Propuesta de Datasets — TPI Análisis de Datos Masivos

*Asignatura: Análisis de Datos Masivos — Maestría en Ciencias de Datos, UCASAL 2026*  
*Estado: Etapa 1 completada — corrida `20261010_185629`, v1.3, SEED=42*

---

## 1. Introducción

El TPI recorre el ciclo completo **BBDD → Consultas → Preparación → Análisis → Indicadores → Visualización → Interpretación → Decisión** a lo largo de cuatro etapas. Se trabaja sobre el dominio **logística de última milla en e-commerce**, combinando dos fuentes:

1. **Olist Brazilian E-Commerce Dataset** ([Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)) — ~100.000 órdenes reales, 9 tablas relacionales, 2016–2018, licencia CC BY-NC-SA 4.0.
2. **Dataset de flota logística sintético calibrado** — 5 tablas generadas con `generate_fleet_dataset.py` v1.3, vinculadas a Olist vía `order_id`, calibradas con distribuciones reales del dataset `dynamic_supply_chain_logistics_dataset.csv` ([Kaggle](https://www.kaggle.com/datasets/datasetengineer/logistics-and-supply-chain-dataset)).

---

## 2. Problema central

**"Optimización de la cadena logística de última milla: análisis del impacto de las condiciones operativas de la flota (tipo de vehículo, comportamiento del conductor, incidentes en ruta, condiciones de tráfico y clima, mantenimiento) sobre los tiempos de entrega y la satisfacción del cliente en un operador de e-commerce brasileño."**

El dataset de Olist expone el *resultado* de la logística (si la orden llegó a tiempo y la reseña del cliente). El dataset de flota expone las *causas* operativas. La combinación permite pasar de análisis descriptivo de síntomas a análisis **causal y prescriptivo**:

- `fleet_deliveries` vincula cada orden con el vehículo, conductor, distancia, estado de la entrega, nivel de congestionamiento y severidad climática.
- `fleet_maintenance` permite analizar si el historial de mantenimiento correctivo se correlaciona con entregas demoradas posteriores.
- `fleet_incidents` documenta las causas operativas de las demoras (avería, tráfico, clima, accidente).
- `eta_variation_hours` en `fleet_deliveries` es la variable objetivo para el Modelo 1 de regresión.

---

## 3. Fuente 1: Olist Brazilian E-Commerce Dataset

**Link:** https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce  
**Licencia:** CC BY-NC-SA 4.0 | **Período:** 2016–2018 | **Volumen:** ~100.000 órdenes, 9 tablas

### Tablas y campos clave

| Tabla | Registros | Campos clave | Rol en el TPI |
|---|---|---|---|
| `olist_orders` | 99.441 | `order_id`, `order_status`, timestamps de entrega y estimado | Tabla central — estado y tiempos |
| `olist_order_items` | 112.650 | `order_id`, `product_id`, `freight_value`, `price` | Costos de flete y asignación de vehículo por peso |
| `olist_customers` | 99.441 | `customer_id`, `customer_state` | Geolocalización del cliente |
| `olist_sellers` | 3.095 | `seller_id`, `seller_state` | Origen del envío — asignación de conductor |
| `olist_products` | 32.952 | `product_id`, `product_weight_g` | `weight_g` determina tipo de vehículo asignado |
| `olist_order_reviews` | 99.224 | `order_id`, `review_score`, `review_comment_message` | Satisfacción del cliente |
| `olist_order_payments` | 103.886 | `order_id`, `payment_type`, `payment_value` | Análisis financiero |
| `olist_geolocation` | 1.000.163 | lat/lng por prefijo CEP | Coordenadas geográficas de Brasil |
| `product_category_name_translation` | 71 | Traducción de categorías al inglés | — |

### Problemas de calidad identificados (resueltos en Etapa 1)

| Problema | Magnitud | Solución en DDL / Acción Etapa 2 |
|---|---|---|
| Coordenadas GPS fuera de Brasil | 42 registros (0.003%) | DROP de CHECKs geográficos en DDL; filtrar en notebook de limpieza |
| Productos con `weight_g = 0` | 4 productos | CHECK `>= 0 OR NULL`; imputar con mediana de categoría en Etapa 2 |
| `order_items` con producto inexistente | variable | Placeholder `unknown_product_placeholder` en DDL; excluir del dataset analítico |
| `review_id` duplicados | 814 casos | Nueva PK `review_pk SERIAL`; usar `review_pk` como clave, no `review_id` |
| Órdenes `delivered` sin `delivery_date` | 8 órdenes | Documentado; excluir del dataset analítico en Etapa 2 |

---

## 4. Fuente 2: Dataset de flota logística (sintético calibrado)

### Proceso de generación — `generate_fleet_dataset.py` v1.3

El script:
1. Lee el dataset de telemetría de Kaggle y extrae distribuciones estadísticas reales: `fuel_consumption_rate`, `eta_variation_hours`, `driver_behavior_score`, `fatigue_monitoring_score`, `delay_probability`, `route_risk_level`, `disruption_likelihood_score`, `shipping_costs`, `traffic_congestion_level` (0–10), `weather_condition_severity` (0–1).
2. Lee las órdenes de Olist con `order_status = 'delivered'` y genera una entrega por orden.
3. Vincula con Olist usando `order_id` como FK en `fleet_deliveries`.

**Reproducibilidad — seeds asignados:**

| Sección | Seed | Propósito |
|---|---|---|
| Global | `SEED = 42` | Inicialización general |
| `fleet_maintenance` | `SEED + 10` | Seed propio para aislarlo de cambios en otras secciones |
| `traffic_congestion_level` | `SEED + 20` | Seed propio para las dos columnas nuevas |
| `weather_condition_severity` | `SEED + 21` | Seed propio |
| `fleet_incidents` sample | `SEED` | vía `random_state=SEED` en pandas |

**Bugs corregidos durante el desarrollo:**

- **v1.1 → v1.2:** tipos de incidente tenían tildes (`"avería"`) pero el CHECK del DDL los espera sin tildes. Fix: reemplazar todas las strings de datos.
- **v1.2 → v1.3:** `n_incidents = len(fleet_deliveries) * 0.15` calculaba el 15% del total (14.470) en lugar de las demoradas (3.612). Fix: `len(delayed_deliveries) * 0.15`. Además se agregó `np.random.seed(SEED + 10)` al inicio de la sección de mantenimiento para aislar su seed.

### Tablas generadas

#### `fleet_vehicles` — 60 vehículos

| Campo | Tipo | Descripción |
|---|---|---|
| `vehicle_id` | INT | PK |
| `plate` | VARCHAR | Formato DENATRAN 2016–2018: `AAA-9999` |
| `type` | VARCHAR | `moto` (25) / `van` (25) / `truck` (10) |
| `brand`, `model` | VARCHAR | Marcas y modelos reales del mercado brasileño |
| `year` | INT | 2010–2017 |
| `capacity_kg` | INT | moto=30 / van=500 / truck=5000 |
| `fuel_type` | VARCHAR | flex/gasolina (motos), flex/diesel (vans), diesel (trucks) |
| `fuel_consumption_rate_lh` | FLOAT | Calibrado desde Kaggle, escalado por tipo |
| `status` | VARCHAR | `activo` (90%) / `baja` (10%) |

#### `fleet_drivers` — 40 conductores

| Campo | Tipo | Descripción |
|---|---|---|
| `driver_id` | INT | PK |
| `name` | VARCHAR | Nombres sintéticos brasileños |
| `license_type` | VARCHAR | A (moto) / B (van) / E (truck) — categorías CNH DETRAN |
| `hire_date` | DATE | 2010–2016 |
| `region_assigned` | VARCHAR | Estado de Brasil |
| `vehicle_id` | INT | FK → `fleet_vehicles` |
| `driver_behavior_score` | FLOAT | Calibrado desde Kaggle (0–1) |
| `fatigue_score_avg` | FLOAT | Calibrado desde Kaggle (0–1) |

#### `fleet_deliveries` — 96.470 registros (tabla de vinculación central)

| Campo | Tipo | Descripción |
|---|---|---|
| `delivery_id` | INT | PK |
| `order_id` | VARCHAR | **FK → `olist_orders`** — clave de vinculación entre fuentes |
| `vehicle_id` | INT | FK → `fleet_vehicles` — asignado por `product_weight_g` |
| `driver_id` | INT | FK → `fleet_drivers` — asignado por `seller_state` |
| `pickup_date` | DATETIME | = `order_purchase_timestamp` de Olist |
| `carrier_pickup_date` | DATETIME | = `order_delivered_carrier_date` de Olist |
| `delivery_date` | DATETIME | = `order_delivered_customer_date` de Olist |
| `distance_km` | FLOAT | Proxy: `shipping_costs / 3.0` (coef. ANTT 2017, rango 5–2500 km) |
| `route_state` | VARCHAR | Estado de origen (= `seller_state`) |
| `delivery_status` | VARCHAR | `on_time` / `delayed` — umbral: percentil 60 de `delay_probability` |
| `eta_variation_hours` | FLOAT | Calibrado desde Kaggle — **variable objetivo Modelo 1** |
| `loading_unloading_time_h` | FLOAT | Calibrado desde Kaggle |
| `route_risk_level` | FLOAT | Calibrado desde Kaggle (0–10) |
| `traffic_congestion_level` | NUMERIC | Calibrado desde Kaggle (0–10), seed SEED+20 |
| `weather_condition_severity` | NUMERIC | Calibrado desde Kaggle (0–1), seed SEED+21 |

**Lógica de asignación de vehículo:**
```
product_weight_g < 300        → moto
300 ≤ product_weight_g < 2000 → van
product_weight_g ≥ 2000       → truck
```

**Distribución resultante:** 72.389 on_time (75%) — 24.081 delayed (25%)

#### `fleet_maintenance` — 698 registros (con SEED+10)

| Campo | Descripción |
|---|---|
| `maintenance_id` | PK |
| `vehicle_id` | FK → `fleet_vehicles` |
| `date` | Distribuido 2016–2018 (8–15 eventos por vehículo) |
| `type` | `preventivo` / `correctivo` |
| `component` | aceite_motor, frenos, motor, transmisión, etc. |
| `cost_brl` | Rango realista por tipo de vehículo |
| `downtime_hours` | preventivo: 1–6 h / correctivo: 4–48 h |
| `mileage_at_service` | Kilometraje acumulado al momento del servicio |

Patrón estacional: la probabilidad de mantenimiento correctivo aumenta en nov–dic (×1.5) y ene–feb (×1.2), coherente con el pico de demanda del e-commerce brasileño visible en Olist.

#### `fleet_incidents` — 3.612 registros (15% de 24.081 demoradas)

| Campo | Descripción |
|---|---|
| `incident_id` | PK |
| `vehicle_id` | FK → `fleet_vehicles` |
| `date` | Entre pickup_date y delivery_date del viaje |
| `type` | `retraso_trafico` (40%) / `condicion_climatica` (25%) / `averia` (20%) / `falla_mecanica_menor` (10%) / `accidente` (5%) |
| `disruption_likelihood` | Calibrado desde Kaggle (0–1) |
| `impact_on_delivery_h` | accidente: 8–48h / averia: 4–24h / trafico: 1–6h |
| `order_id` | FK → `fleet_deliveries.order_id` (nullable) |

---

## 5. Esquema de integración entre fuentes

```
┌──────────────────────────────────────────────────────────────────┐
│                        FUENTE 1: OLIST                           │
│                                                                  │
│  olist_customers ──► olist_orders ◄──── olist_order_items        │
│                          │  │                   │                │
│                          │  └── olist_reviews   olist_products   │
│                          │  └── olist_payments  (product_weight_g│
│                          │                       → tipo vehiculo)│
│              olist_sellers + olist_geolocation                   │
│              (seller_state → asignacion de conductor)            │
└──────────────────────────┬───────────────────────────────────────┘
                           │ order_id (FK)
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│                  TABLA DE VINCULACIÓN                            │
│                   fleet_deliveries                               │
│  order_id FK | vehicle_id FK | driver_id FK                      │
│  delivery_status | eta_variation_hours | distance_km             │
│  route_risk_level | traffic_congestion_level                     │
│  weather_condition_severity | loading_unloading_time_h           │
└───────┬──────────────────────────────────┬───────────────────────┘
        │ vehicle_id (FK)                  │ vehicle_id (FK)
        ▼                                  ▼
┌───────────────────┐            ┌──────────────────────────┐
│  fleet_vehicles   │            │    fleet_maintenance     │
│  type, capacity   │            │    type, component       │
│  fuel_type, year  │            │    cost_brl, downtime_h  │
└───────────────────┘            └──────────────────────────┘
        │ vehicle_id (FK)
        ▼
┌───────────────────┐
│  fleet_incidents  │◄── order_id (FK, nullable)
│  type, impact_h   │
│  disruption_score │
└───────────────────┘
        ▲
        │ driver_id (FK)
┌───────────────────┐
│  fleet_drivers    │
│  behavior_score   │
│  fatigue_score    │
└───────────────────┘
```

---

## 6. Preguntas analíticas — Etapa 1

### Q1 — Factores de demora por estado × tipo de vehículo

Tablas: `fleet_deliveries`, `fleet_vehicles`, `fleet_drivers`, `olist_orders`, `olist_customers`  
Resultado: 80 combinaciones (estado × tipo de vehículo) con al menos 10 entregas

**Hallazgos clave:** las combinaciones con mayor tasa de demora se concentran en estados con mayor distancia de distribución (SP, MG, PR) y en motos, que tienen la mayor exposición a condiciones climáticas y de tráfico. El `traffic_congestion_level` promedio es consistentemente mayor en entregas demoradas.

### Q2 — Driver behavior score vs review score por conductor

Tablas: `fleet_deliveries`, `fleet_drivers`, `olist_order_reviews`  
Resultado: 40 filas (una por conductor), clasificados en perfil alto/medio/bajo

**Hallazgos clave:** se observa correlación positiva entre `driver_behavior_score` y `review_score` promedio. Los conductores con score < 0.4 (perfil bajo) muestran una tasa de demora promedio superior a los de perfil alto.

### Q3 — Estacionalidad de mantenimientos correctivos vs demoras mensuales

Tablas: `fleet_maintenance`, `fleet_deliveries`, `olist_orders`  
Resultado: 33 filas (año × mes con datos)

**Hallazgos clave:** la concentración de mantenimientos correctivos en nov–dic coincide con el pico de órdenes demoradas de Olist. El `congestion_promedio` aumenta en los mismos meses, consistente con el pico de temporada alta del e-commerce brasileño.

**Nota de performance:** esta consulta hace spill a disco (784 bloques, 6.1 MB) porque el `HashAggregate` sobre 96.470 filas × `olist_orders` supera el `work_mem = 4 MB` por defecto. Con `SET work_mem = '16 MB'` el spill desaparece y el tiempo baja ~40%.

### Q4 — Tipos de incidente: impacto en horas y cobertura

Tablas: `fleet_incidents`, `fleet_deliveries`, `fleet_vehicles`  
Resultado: 5 filas (una por tipo de incidente)

**Hallazgos clave:** `accidente` tiene el mayor impacto promedio en horas pero la menor frecuencia (5%). `retraso_trafico` es el más frecuente (40%) con impacto moderado. El índice `idx_del_status` permite filtrar eficientemente las 24.081 entregas demoradas (−35.3% de tiempo de ejecución vs sin índice).

### Q5 — Costo de mantenimiento vs rendimiento por tipo de vehículo

Tablas: `fleet_maintenance`, `fleet_vehicles`, `fleet_deliveries`  
Resultado: 3 filas (moto / van / truck)

**Hallazgos clave:** los trucks tienen el mayor costo de mantenimiento correctivo pero también la mayor capacidad de carga. Las motos muestran la mayor tasa de entregas a tiempo (75%+) pero el mayor impacto de clima y tráfico. La consulta es completamente interna a las tablas de flota — tiempo de ejecución significativamente menor que Q1 y Q2, que hacen JOIN a Olist.

---

## 7. Resultados de performance — Etapa 1

### Tabla comparativa final (corrida `20261010_185629`, caché frío)

| Q | Sin índices (ms) | Con índices (ms) | Δ | Índice activo | Plan principal |
|---|---:|---:|---:|---|---|
| Q1 | 239.6 | 162.7 | **−32.1%** | ninguno (Seq Scan correcto) | Parallel Hash Join × 4 tablas, 1 worker |
| Q2 | 160.4 | 112.4 | **−29.9%** | ninguno (Seq Scan correcto) | Parallel Hash Right Join, 1 worker |
| Q3 | 214.5 | 229.4 | +7.0% | ninguno — limitante es memoria | Hash Right Join + spill 784 bloques (6.1 MB) |
| Q4 | 60.0 | 38.8 | **−35.3%** | `idx_del_status` activo | Bitmap Heap Scan → Hash Left Join |
| Q5 | 111.3 | 89.8 | **−19.3%** | ninguno (Seq Scan correcto) | Merge Join (plan optimizado vs Nested Loop sin idx) |

### Interpretación de los resultados

**Cuatro de cinco consultas mejoran con índices**, con una mejora promedio del 29% para Q1, Q2, Q4 y Q5.

El planner de PostgreSQL elige correctamente `Seq Scan` en Q1, Q2 y Q5 incluso con índices disponibles. Esto ocurre porque estas consultas necesitan procesar el 100% de las filas de `fleet_deliveries` (para el `GROUP BY`) — un `Seq Scan` en ese caso es más eficiente que un `Index Scan` porque lee las páginas en secuencia en un solo pass. Los índices de las secciones A–E están diseñados para filtros selectivos de Etapa 2, no para los agregados completos de Etapa 1.

**Q3 es el único caso que empeora** y la causa no es el plan de ejecución sino la configuración de memoria: el `HashAggregate` necesita más de 4 MB de `work_mem` para procesar el JOIN de 96.470 filas sin spillover. Este es un hallazgo valioso: muestra que los índices no son siempre la solución y que `work_mem` es el parámetro relevante en este caso.

**Q4 muestra la mayor mejora (−35.3%)** por ser el único donde el índice reduce genuinamente el I/O: `idx_del_status` permite un Bitmap Index Scan que lee solo las 24.081 filas demoradas (25%) en lugar de las 96.470 totales. Es el caso de libro de índice parcial efectivo.

---

## 8. Cobertura de las cuatro etapas del TPI

| Etapa | Requerimiento | Cobertura |
|---|---|---|
| **Etapa 1** | SGBD relacional, SQL, plan de ejecución, análisis de I/O | PostgreSQL 15. 14 tablas. `fleet_deliveries` (96K) + `olist_order_items` (113K) + `olist_geolocation` (1M). EXPLAIN ANALYZE con comparación sin/con índices documentada. |
| **Etapa 2** | Dataset analítico, EDA, estadística descriptiva | Limpieza: weight_g=0, coords fuera de Brasil, 8 órdenes sin delivery_date. EDA: distribución de `delivery_status`, correlaciones `traffic_congestion_level` y `weather_condition_severity` vs demoras, análisis temporal. |
| **Etapa 3** | ≥2 modelos predictivos, ≥10 KPIs | **Modelo 1 (Regresión):** `eta_variation_hours` ~ `distance_km` + `route_risk_level` + `vehicle_type` + `driver_behavior_score` + `traffic_congestion_level` + `weather_condition_severity`. **Modelo 2 (Clasificación):** `delivery_status` (on_time/delayed). |
| **Etapa 4** | Dashboard ejecutivo, analítico y de decisión | **Ejecutivo:** OTD rate, review score, vehículos de mayor riesgo. **Analítico:** drill-down por estado, tipo de vehículo, conductor. **Decisión:** predicción de riesgo por entrega, alertas de mantenimiento preventivo. |

---

## 9. KPIs propuestos (≥ 14)

| # | KPI | Fórmula / Fuente | Tipo |
|---|---|---|---|
| 1 | OTD Rate (Olist) | Órdenes ≤ estimated_delivery / Total entregadas — `olist_orders` | Logístico |
| 2 | Demora promedio (días) | AVG(delivered − estimated) donde > 0 — `olist_orders` | Logístico |
| 3 | ETA Variation promedio (h) | AVG(`eta_variation_hours`) por vehículo/región/período — `fleet_deliveries` | Logístico |
| 4 | Tasa demoras por tipo de vehículo | COUNT(delayed) / COUNT total por `vehicle_type` | Flota |
| 5 | Congestionamiento promedio en demoradas | AVG(`traffic_congestion_level`) WHERE delivery_status='delayed' | Flota |
| 6 | Severidad climática en demoradas | AVG(`weather_condition_severity`) WHERE delivery_status='delayed' | Flota |
| 7 | Review score promedio | AVG(`review_score`) por período/estado — `olist_order_reviews` | Satisfacción |
| 8 | % reseñas ≤ 2 estrellas | COUNT(score ≤ 2) / COUNT total con reseña | Satisfacción |
| 9 | Driver behavior score promedio | AVG(`driver_behavior_score`) por conductor/región — `fleet_drivers` | Conductores |
| 10 | Ratio preventivo/correctivo | COUNT(preventivo) / COUNT(correctivo) por vehículo — `fleet_maintenance` | Mantenimiento |
| 11 | Costo promedio correctivo por tipo | AVG(`cost_brl`) WHERE type='correctivo' GROUP BY vehicle_type | Mantenimiento |
| 12 | Tiempo de inactividad promedio | AVG(`downtime_hours`) por tipo de mantenimiento y mes | Mantenimiento |
| 13 | Tasa de incidentes por vehículo | COUNT(incidents) / COUNT(deliveries) por vehicle_id | Incidentes |
| 14 | Impacto promedio de incidentes | AVG(`impact_on_delivery_h`) GROUP BY incident_type | Incidentes |
| 15 | Costo de flete promedio por kg | AVG(freight_value / product_weight_g) — `olist_order_items` + `olist_products` | Financiero |

---

## 10. Próximos pasos — Etapa 2

- [x] Descargar los 9 CSV de Olist y el dataset de telemetría de Kaggle.
- [x] Instalar PostgreSQL y crear `olist_logistics_db`.
- [x] DDL Olist con fixes de calidad (01_ddl_olist.sql). DDL AUDIT 7/7 OK.
- [x] DDL Flota con columnas traffic y weather (02_ddl_fleet.sql). DDL AUDIT 7/7 OK.
- [x] Import de 14 tablas con DATA AUDIT 10/10 OK (03_import_data.sql).
- [x] Diagnóstico de calidad post-import (03c_post_import.sql). 5 problemas documentados.
- [x] 5 consultas analíticas desarrolladas y verificadas.
- [x] EXPLAIN ANALYZE sin/con índices — análisis de performance completo.
- [x] `generate_fleet_dataset.py` v1.3 con reproducibilidad garantizada (SEED=42, sub-seeds documentados, bug de n_incidents corregido).
- [ ] **Etapa 2 — Notebook `01_limpieza.ipynb`:** imputar weight_g=0, filtrar coords fuera de Brasil, excluir 8 órdenes sin delivery_date.
- [ ] **Etapa 2 — Notebook `02_eda.ipynb`:** distribución de `eta_variation_hours`, correlación conductor↔reseña, análisis de `traffic_congestion_level` y `weather_condition_severity` vs `delivery_status`.
- [ ] **Etapa 2 — Dataset analítico:** JOIN principal 14 tablas → 1 dataset unificado.
