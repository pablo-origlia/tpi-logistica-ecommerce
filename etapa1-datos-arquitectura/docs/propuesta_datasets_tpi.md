# Propuesta de Datasets — TPI Analisis de Datos Masivos

*Asignatura: Analisis de Datos Masivos — Maestria en Ciencias de Datos, UCASAL 2026*

---

## 1. Introduccion

El TPI requiere recorrer el ciclo completo **BBDD → Consultas → Preparacion → Analisis → Indicadores → Visualizacion → Interpretacion → Decision** a lo largo de cuatro semanas/etapas. La eleccion de los datasets debe garantizar: suficiente volumen de datos para justificar analisis de datos masivos, estructura relacional clara para SQL, variedad de tecnicas analiticas aplicables (descriptivo, predictivo, prescriptivo), y un problema empresarial real y concreto.

Se propone trabajar sobre el dominio **logistica de ultima milla en e-commerce**, combinando dos fuentes:

1. **Olist Brazilian E-Commerce Dataset** (Kaggle) — fuente principal: ~100.000 ordenes reales, 9 tablas relacionales con datos de clientes, vendedores, productos, pagos y resenas.
2. **Dataset de flota logistica sintetico** — fuente complementaria: 5 tablas generadas con `generate_fleet_dataset.py`, calibradas con distribuciones reales del dataset `dynamic_supply_chain_logistics_dataset.csv` (Kaggle) y vinculadas a Olist via `order_id`.

---

## 2. Problema central

**"Optimizacion de la cadena logistica de ultima milla: analisis del impacto de las condiciones operativas de la flota (tipo de vehiculo, comportamiento del conductor, incidentes en ruta, mantenimiento) sobre los tiempos de entrega y la satisfaccion del cliente en un operador de e-commerce brasileno."**

### Justificacion

El dataset de Olist expone el *resultado* de la logistica: si una orden llego a tiempo y la resena del cliente. Sin embargo, no expone las *causas* operativas. Incorporar el dataset de flota permite pasar de un analisis descriptivo de sintomas (demoras, resenas bajas) a uno **causal y prescriptivo**:

- `fleet_deliveries` vincula cada orden de Olist con el vehiculo, conductor, distancia y estado de la entrega (`on_time` / `delayed`).
- `fleet_maintenance` permite analizar si el historial de mantenimiento correctivo de un vehiculo se correlaciona con sus entregas demoradas posteriores.
- `fleet_incidents` documenta las causas operativas de las demoras (averia, trafico, clima, accidente).
- La variable `eta_variation_hours` en `fleet_deliveries` es la variable objetivo natural para modelos de regresion.

Este problema es relevante porque:
- Involucra decisiones operativas concretas: asignacion de vehiculos por peso de producto, priorizacion de mantenimiento preventivo, gestion de conductores por region.
- Integra datos estructurados (Olist + flota) y semiestructurados (resenas de texto en `review_comment_message`).
- Habilita dos modelos predictivos sobre variables y algoritmos distintos (ver Etapa 3).
- Genera un dashboard con tres vistas naturales: ejecutiva, analitica y de decision.

---

## 3. Fuente 1: Olist Brazilian E-Commerce Dataset

**Link:** https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce  
**Licencia:** CC BY-NC-SA 4.0 | **Periodo:** 2016–2018 | **Volumen:** ~100.000 ordenes, 9 tablas

### Tablas y campos clave

| Tabla | Registros aprox. | Campos clave | Rol en el TPI |
|---|---|---|---|
| `olist_orders` | 99.441 | `order_id`, `customer_id`, `order_status`, `order_purchase_timestamp`, `order_delivered_customer_date`, `order_estimated_delivery_date` | Tabla central — estado y tiempos de entrega |
| `olist_order_items` | 112.650 | `order_id`, `product_id`, `seller_id`, `freight_value`, `price` | Detalle de items y costos de flete |
| `olist_customers` | 99.441 | `customer_id`, `customer_zip_code_prefix`, `customer_city`, `customer_state` | Geolocalizacion del cliente |
| `olist_sellers` | 3.095 | `seller_id`, `seller_zip_code_prefix`, `seller_city`, `seller_state` | Origen del envio — determina asignacion de conductor |
| `olist_products` | 32.951 | `product_id`, `product_category_name`, `product_weight_g` | `product_weight_g` determina tipo de vehiculo asignado |
| `olist_order_reviews` | 99.224 | `review_id`, `order_id`, `review_score`, `review_comment_message` | Satisfaccion del cliente — variable de impacto final |
| `olist_order_payments` | 103.886 | `order_id`, `payment_type`, `payment_value` | Analisis financiero |
| `olist_geolocation` | 1.000.163 | `geolocation_zip_code_prefix`, `geolocation_lat`, `geolocation_lng` | Coordenadas para analisis espacial de rutas |
| `product_category_name_translation` | 71 | `product_category_name`, `product_category_name_english` | Traduccion de categorias |

### Tipos de datos presentes
- **Estructurados:** todas las tablas relacionales con PKs y FKs definidas.
- **Semiestructurados:** `review_comment_message` (texto libre) — permite analisis de sentimiento como extension.
- **Temporales:** multiples timestamps en `olist_orders` → analisis de series temporales y calculo de demoras.
- **Geoespaciales:** lat/lng en `olist_geolocation` → referencia geografica real de Brasil para los registros de flota.

---

## 4. Fuente 2: Dataset de flota logistica (sintetico calibrado)

### Proceso de generacion

Las 5 tablas de flota se generan con `generate_fleet_dataset.py` (v1.1), que:

1. **Lee el dataset Kaggle** (`dynamic_supply_chain_logistics_dataset.csv`) y extrae distribuciones estadisticas reales: media y desviacion de `fuel_consumption_rate`, `eta_variation_hours`, `driver_behavior_score`, `fatigue_monitoring_score`, `delay_probability`, `route_risk_level`, `disruption_likelihood_score` y `shipping_costs`.
2. **Lee los datasets de Olist** y filtra solo las ordenes con `order_status = 'delivered'`.
3. **Genera cada tabla** usando esas distribuciones como parametros, garantizando coherencia estadistica con datos reales.
4. **Vincula con Olist** usando `order_id` como FK en `fleet_deliveries`.
5. **Guarda un log** en `output/fleet_generation_log.txt` con metricas de la generacion.

**Reproducibilidad:** `SEED = 42` fijada globalmente; sub-seeds documentadas por bloque (`SEED+10` para `distance_km`).

### Tablas generadas

#### `fleet_vehicles` — 60 vehiculos

| Campo | Tipo | Descripcion |
|---|---|---|
| `vehicle_id` | INT | PK |
| `plate` | VARCHAR | Formato DENATRAN 2016-2018: `AAA-9999` |
| `type` | VARCHAR | `moto` (25) / `van` (25) / `truck` (10) |
| `brand` | VARCHAR | Marcas reales del mercado brasileno |
| `model` | VARCHAR | Modelos reales: CG 160, Ducato, Accelo 1016, etc. |
| `year` | INT | 2010–2017 |
| `capacity_kg` | INT | moto=30 / van=500 / truck=5000 |
| `fuel_type` | VARCHAR | flex/gasolina (motos), flex/diesel/gas_natural (vans), diesel/diesel_b10 (trucks) |
| `fuel_consumption_rate_lh` | FLOAT | Calibrado desde Kaggle, escalado por tipo de vehiculo |
| `status` | VARCHAR | activo (90%) / baja (10%) |

#### `fleet_drivers` — 40 conductores

| Campo | Tipo | Descripcion |
|---|---|---|
| `driver_id` | INT | PK |
| `name` | VARCHAR | Nombres sinteticos brasilenos |
| `license_type` | VARCHAR | A (moto) / B (van) / C (truck rigido) — categorias CNH DETRAN |
| `hire_date` | DATE | 2010–2016 |
| `region_assigned` | VARCHAR | Estado de Brasil (SP, RJ, MG, RS, PR, etc.) |
| `vehicle_id` | INT | FK → `fleet_vehicles` |
| `driver_behavior_score` | FLOAT | Calibrado desde Kaggle (0–1) |
| `fatigue_score_avg` | FLOAT | Calibrado desde Kaggle (0–1) |

#### `fleet_deliveries` — ~96.000 registros *(tabla de vinculacion central)*

| Campo | Tipo | Descripcion |
|---|---|---|
| `delivery_id` | INT | PK |
| `order_id` | VARCHAR | **FK → `olist_orders`** — clave de vinculacion entre fuentes |
| `vehicle_id` | INT | FK → `fleet_vehicles` — asignado por `product_weight_g` |
| `driver_id` | INT | FK → `fleet_drivers` — asignado por `seller_state` |
| `pickup_date` | DATETIME | = `order_purchase_timestamp` de Olist |
| `carrier_pickup_date` | DATETIME | = `order_delivered_carrier_date` de Olist |
| `delivery_date` | DATETIME | = `order_delivered_customer_date` de Olist |
| `distance_km` | FLOAT | Proxy: `shipping_costs / 3.0` (coef. ANTT 2017, rango 5–2500 km) |
| `route_state` | VARCHAR | Estado de origen (= `seller_state`) |
| `delivery_status` | VARCHAR | `on_time` / `delayed` — umbral: percentil 60 de `delay_probability` |
| `eta_variation_hours` | FLOAT | Calibrado desde Kaggle (rango –12 a +30 h) — **variable objetivo** |
| `loading_unloading_time_h` | FLOAT | Calibrado desde Kaggle `loading_unloading_time` |
| `route_risk_level` | FLOAT | Calibrado desde Kaggle (escala 0–10) |

**Logica de asignacion de vehiculo:**
```
product_weight_g < 300 g   → moto
300 ≤ product_weight_g < 2000 g → van
product_weight_g ≥ 2000 g  → truck
```

#### `fleet_maintenance` — ~720 registros

| Campo | Tipo | Descripcion |
|---|---|---|
| `maintenance_id` | INT | PK |
| `vehicle_id` | INT | FK → `fleet_vehicles` |
| `date` | DATE | Distribuido 2016–2018 (8–15 eventos por vehiculo) |
| `type` | VARCHAR | `preventivo` / `correctivo` |
| `component` | VARCHAR | aceite_motor, frenos, motor, transmision, etc. |
| `cost_brl` | FLOAT | Rango realista por tipo de vehiculo y tipo de mantenimiento |
| `downtime_hours` | FLOAT | preventivo: 1–6 h / correctivo: 4–48 h |
| `mileage_at_service` | INT | Kilometraje acumulado al momento del servicio |

**Patron estacional:** probabilidad de mantenimiento correctivo aumenta en nov–dic (×1.5–1.6) y ene–feb (×1.2–1.3), coherente con el pico de demanda del e-commerce brasileno visible en Olist.

#### `fleet_incidents` — ~15% del subconjunto de ordenes demoradas

| Campo | Tipo | Descripcion |
|---|---|---|
| `incident_id` | INT | PK |
| `vehicle_id` | INT | FK → `fleet_vehicles` |
| `date` | DATE | Entre `pickup_date` y `delivery_date` del viaje |
| `type` | VARCHAR | retraso_trafico (40%) / condicion_climatica (25%) / averia (20%) / falla_mecanica_menor (10%) / accidente (5%) |
| `disruption_likelihood` | FLOAT | Calibrado desde Kaggle `disruption_likelihood_score` |
| `impact_on_delivery_h` | FLOAT | Impacto en horas segun tipo: accidente 8–48h, averia 4–24h, trafico 1–6h |
| `order_id` | VARCHAR | FK → `fleet_deliveries.order_id` (nullable — no toda demora tiene incidente) |

---

## 5. Esquema de integracion entre fuentes

```
┌──────────────────────────────────────────────────────────────────┐
│                        FUENTE 1: OLIST                            │
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
│              TABLA DE VINCULACION                                 │
│                   fleet_deliveries                               │
│  order_id FK | vehicle_id FK | driver_id FK                      │
│  delivery_status | eta_variation_hours | distance_km             │
│  route_risk_level | loading_unloading_time_h                     │
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

**Joins principales para el dataset analitico:**
```sql
-- Base del dataset analitico
SELECT  o.order_id,
        o.order_status,
        (EXTRACT(EPOCH FROM (o.order_delivered_customer_date
                           - o.order_estimated_delivery_date)) / 3600)
            AS delay_hours_olist,
        fd.eta_variation_hours,
        fd.delivery_status,
        fd.distance_km,
        fd.route_risk_level,
        fv.type          AS vehicle_type,
        fdr.driver_behavior_score,
        fdr.fatigue_score_avg,
        r.review_score
FROM    olist_orders          o
JOIN    fleet_deliveries      fd  ON fd.order_id    = o.order_id
JOIN    fleet_vehicles        fv  ON fv.vehicle_id  = fd.vehicle_id
JOIN    fleet_drivers         fdr ON fdr.driver_id  = fd.driver_id
LEFT JOIN olist_order_reviews r   ON r.order_id     = o.order_id;
```

---

## 6. Preguntas analiticas — Etapa 1

1. **¿Cuales son los principales factores de la flota (`route_risk_level`, `vehicle_type`, `driver_behavior_score`) asociados a las entregas demoradas, y como se distribuyen por estado de Brasil?**  
   → JOIN entre `fleet_deliveries`, `fleet_vehicles`, `fleet_drivers`, `olist_orders`, `olist_customers`. Identifica regiones y perfiles operativos criticos.

2. **¿Existe correlacion entre el `driver_behavior_score` promedio de un conductor y el `review_score` promedio de las ordenes que entrego?**  
   → JOIN entre `fleet_deliveries`, `fleet_drivers`, `olist_order_reviews`. Hipotesis: conductores con menor score generan peores resenas.

3. **¿En que meses del ano se concentran mas los mantenimientos correctivos, y coincide con el pico de ordenes demoradas en Olist?**  
   → `fleet_maintenance` (agrupado por mes/tipo) vs. `olist_orders` (agrupado por mes con `delivery_status = 'delayed'`). Valida el patron estacional nov–dic.

4. **¿Que tipos de incidente logistico generan mayor impacto promedio en horas de demora, y que porcentaje de las ordenes demoradas tienen un incidente registrado asociado?**  
   → `fleet_incidents` JOIN `fleet_deliveries`. Permite cuantificar las causas documentadas de demoras.

5. **¿El costo promedio de mantenimiento correctivo por tipo de vehiculo justifica la diferencia de rendimiento logistico (tasa de entregas a tiempo) entre motos, vans y trucks?**  
   → `fleet_maintenance` JOIN `fleet_vehicles` JOIN `fleet_deliveries`. Analisis de costo-beneficio por segmento de flota.

---

## 7. Cobertura de las cuatro etapas del TPI

| Etapa | Requerimiento | Cobertura con los datasets elegidos |
|---|---|---|
| **Etapa 1** | SGBD relacional, consultas SQL, plan de ejecucion, analisis de I/O | PostgreSQL. 14 tablas (9 Olist + 5 flota). `fleet_deliveries` (~96k filas) + `olist_order_items` (~113k) + `olist_geolocation` (~1M) justifican analisis de performance, indices sobre `order_id` y `vehicle_id`, y comparacion de planes de ejecucion con y sin indices. |
| **Etapa 2** | Dataset analitico, EDA, estadistica descriptiva | Limpieza: nulos en `seller_state` (~1% de ordenes), valores extremos en `distance_km` y `eta_variation_hours`, inconsistencias en fechas de entrega. EDA: distribucion de `delivery_status`, correlaciones entre variables de flota y `review_score`, analisis temporal de demoras por mes/ano. |
| **Etapa 3** | ≥2 modelos predictivos, ≥10 KPIs | **Modelo 1 (Regresion):** prediccion de `eta_variation_hours` con variables `distance_km`, `route_risk_level`, `vehicle_type`, `driver_behavior_score`, `fatigue_score_avg` → Random Forest Regressor. **Modelo 2 (Clasificacion):** prediccion de `delivery_status` (on_time/delayed) → Arbol de decision / Regresion logistica. **Descriptivo:** clustering de vehiculos por perfil de riesgo. |
| **Etapa 4** | Dashboard ejecutivo, analitico y de decision | **Ejecutiva:** KPIs de OTD, review score promedio, vehiculos con mayor tasa de incidentes. **Analitica:** drill-down por estado, tipo de vehiculo, conductor, mes. **Decision:** prediccion de riesgo por entrega, alertas de mantenimiento preventivo, recomendaciones de reasignacion de rutas. |

---

## 8. KPIs tentativos (≥ 10)

| # | KPI | Definicion / Formula | Fuente | Tipo |
|---|---|---|---|---|
| 1 | **OTD Rate (Olist)** | Ordenes entregadas ≤ `order_estimated_delivery_date` / Total entregadas | `olist_orders` | Logistico |
| 2 | **Demora promedio (dias)** | AVG(`order_delivered` − `order_estimated`) solo registros > 0 | `olist_orders` | Logistico |
| 3 | **ETA Variation promedio (h)** | AVG(`eta_variation_hours`) por vehiculo / region / periodo | `fleet_deliveries` | Logistico |
| 4 | **Tasa de entregas demoradas por tipo de vehiculo** | COUNT(`delivery_status='delayed'`) / COUNT total — por `vehicle_type` | `fleet_deliveries`, `fleet_vehicles` | Flota |
| 5 | **Score promedio de resena** | AVG(`review_score`) por periodo / estado / categoria de producto | `olist_order_reviews` | Satisfaccion |
| 6 | **% resenas ≤ 2 estrellas** | COUNT(`review_score` ≤ 2) / COUNT total con resena | `olist_order_reviews` | Satisfaccion |
| 7 | **Driver behavior score promedio** | AVG(`driver_behavior_score`) por conductor / region | `fleet_drivers` | Conductores |
| 8 | **Indice de fatiga promedio** | AVG(1 − `fatigue_score_avg`) — invertido: mayor = mas fatiga | `fleet_drivers` | Conductores |
| 9 | **Ratio preventivo / correctivo** | COUNT(`type='preventivo'`) / COUNT(`type='correctivo'`) por vehiculo | `fleet_maintenance` | Mantenimiento |
| 10 | **Costo promedio de mantenimiento correctivo por tipo** | AVG(`cost_brl`) WHERE `type='correctivo'` GROUP BY `vehicle_type` | `fleet_maintenance`, `fleet_vehicles` | Mantenimiento |
| 11 | **Tiempo promedio de inactividad por mantenimiento** | AVG(`downtime_hours`) por tipo de mantenimiento y mes | `fleet_maintenance` | Mantenimiento |
| 12 | **Tasa de incidentes por vehiculo** | COUNT(`incidents`) / COUNT(`deliveries`) GROUP BY `vehicle_id` | `fleet_incidents`, `fleet_deliveries` | Incidentes |
| 13 | **Impacto promedio de incidentes en demora** | AVG(`impact_on_delivery_h`) GROUP BY `incident_type` | `fleet_incidents` | Incidentes |
| 14 | **Costo de flete promedio por kg** | AVG(`freight_value` / `product_weight_g`) | `olist_order_items`, `olist_products` | Financiero |

---

## 9. Notas sobre tipos de datos y cobertura del programa

| Tipo de dato (Unidad 1) | Fuente | Ejemplos |
|---|---|---|
| **Estructurados** | Olist (9 tablas) + 5 tablas de flota | Ordenes, pagos, vendedores, vehiculos, mantenimientos |
| **Semiestructurados** | `olist_order_reviews.review_comment_message` | Texto libre de resenas de clientes |
| **IoT / Alta frecuencia** | `dynamic_supply_chain_logistics_dataset.csv` (Kaggle, como fuente de calibracion) | Telemetria horaria: GPS, temperatura, comportamiento del conductor, `delay_probability` — los parametros estadisticos de este dataset se transfieren a las tablas de flota, no las filas crudas |

El dataset Kaggle de telemetria **no se carga en la base SQL** como tabla de hechos, sino que se usa en el script Python como fuente de distribuciones para calibrar los valores sinteticos. Esto es coherente con la realidad: en un operador de logistica, los datos de telemetria se agregan antes de ser cargados al DWH operacional.

---

## 10. Proximos pasos — Etapa 1

- [ ] Descargar los 9 CSV de Olist desde Kaggle y el dataset `dynamic_supply_chain_logistics_dataset.csv`.
- [ ] Instalar PostgreSQL y crear la base de datos `olist_logistics_db`.
- [ ] Escribir el DDL para las 9 tablas de Olist con PKs, FKs y tipos de datos correctos (`CREATE TABLE` con constraints).
- [ ] Importar los CSVs de Olist con `COPY` o `pg_bulkload`.
- [ ] Ejecutar `generate_fleet_dataset.py` y verificar el `fleet_generation_log.txt`.
- [ ] Crear el DDL para las 5 tablas de flota y cargar los CSVs generados.
- [ ] Desarrollar las 5 consultas SQL de las preguntas analiticas.
- [ ] Capturar planes de ejecucion con `EXPLAIN ANALYZE` antes y despues de crear indices sobre `order_id` y `vehicle_id`.
- [ ] Documentar metricas de performance (tiempo de ejecucion, filas procesadas, I/O) para la presentacion de Etapa 1.
- [ ] Completar el diccionario de datos con la documentacion de vinculacion ficticia del `fleet_generation_log.txt`.

