# Propuesta del proyecto — Optimización de la cadena logística de última milla

*Asignatura: Análisis de Datos Masivos — Maestría en Ciencias de Datos, UCASAL 2026*

Este documento define el problema, las fuentes de datos, la estructura de la base, las preguntas analíticas, los indicadores y el plan de trabajo del TPI. El proyecto recorre el ciclo **BBDD → Consultas → Preparación → Análisis → Indicadores → Visualización → Interpretación → Decisión** a lo largo de cuatro etapas.

---

## 1. Problema, contexto y usuarios

**Problema.** *Optimización de la cadena logística de última milla: análisis del impacto de las condiciones operativas de la flota (tipo de vehículo, comportamiento del conductor, incidentes en ruta, tráfico, clima y mantenimiento) sobre los tiempos de entrega y la satisfacción del cliente en un operador de e-commerce brasileño.*

**Contexto.** En el e-commerce, la última milla (del centro de distribución al cliente) concentra buena parte del costo logístico y define la experiencia de compra. Las órdenes de Olist, un marketplace brasileño, permiten observar el *resultado* de la logística (si cada orden llegó antes o después de la fecha prometida y qué reseña dejó el cliente). Los datos de flota aportan variables operativas candidatas a explicar ese resultado.

**Usuarios de la información y decisiones que se mejoran**

| Usuario | Decisiones |
|---|---|
| Gerencia de operaciones logísticas | Dónde reforzar capacidad y cómo prometer plazos por destino y época del año |
| Jefatura de flota y mantenimiento | Plan de mantenimiento preventivo; asignación de vehículos y conductores |
| Calidad y atención al cliente | Anticipar y mitigar las entregas tardías que deterioran la satisfacción |

**Tipo de análisis.** Descriptivo (qué ocurre y dónde), predictivo (tiempo de entrega y probabilidad de demora) y prescriptivo (priorización de destinos y rutas con mayor demora real y volumen).

---

## 2. Fuentes de datos y caracterización

### 2.1 Fuentes

| Fuente | Origen | Naturaleza | Volumen |
|---|---|---|---|
| **Olist Brazilian E-Commerce** | [Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce), CC BY-NC-SA 4.0 | Datos reales, anonimizados, 2016–2018 | 9 tablas, ~1,55 millones de filas |
| **Flota logística sintética** | Generada con `scripts/generate_fleet_dataset.py` | Derivada de datos reales de Olist o simulada condicionada a ellos | 5 tablas, ~101.000 filas |
| **Logistics and Supply Chain** | [Kaggle](https://www.kaggle.com/datasets/datasetengineer/logistics-and-supply-chain-dataset) | Datos de telemetría logística; solo aporta las distribuciones marginales de las variables simuladas | 1 archivo CSV |

**Clave de vinculación entre fuentes:** `olist_orders.order_id` = `fleet_deliveries.order_id`.

### 2.2 Caracterización por tipo de dato

| Tipo | Datos | Dónde | Tratamiento |
|---|---|---|---|
| **Estructurados** | Las 14 tablas relacionales: órdenes, ítems, clientes, vendedores, productos, pagos, coordenadas y flota (numéricos, categóricos, fechas y coordenadas) | PostgreSQL | Consultas SQL, vistas y dataset analítico |
| **No estructurados** | Texto libre de las reseñas (`review_comment_title` y `review_comment_message`, en portugués). 40.977 de las 99.224 reseñas tienen mensaje | `olist_order_reviews` | Se conserva en la base; el análisis usa solo la puntuación y la indicación de si hay comentario. Queda abierta la posibilidad de un análisis de sentimiento |
| **Semiestructurados** | No hay en las fuentes (sin JSON, XML ni registros de eventos) | — | — |

### 2.3 Qué es real y qué es simulado

| Variable | Naturaleza |
|---|---|
| Fechas de compra, despacho, entrega y promesa; estados; pesos; precios y fletes; reseñas; pagos | **Real** (Olist) |
| `fleet_deliveries.delivery_status`, `distance_km`, `eta_variation_hours` | **Derivada de datos reales** (demora de Olist, geografía y tiempos de tránsito) |
| `traffic_congestion_level`, `weather_condition_severity`, `route_risk_level`, `loading_unloading_time_h` | **Simulada**, condicionada a señales reales |
| Conductores (`driver_behavior_score`, `fatigue_score_avg`), mantenimientos e incidentes | **Simulada**, condicionada a señales reales y al uso de los vehículos |

> **Advertencia metodológica.** Las asociaciones entre las variables simuladas y la demora real están impuestas por el generador: describen un escenario, no evidencia empírica. Además, al generarse condicionadas al resultado, usarlas como predictores equivale a una fuga de información. Por eso los modelos de la Etapa 3 se evalúan con dos conjuntos de predictores: **A** (variables reales conocidas al comprar) y **B** (A más las variables simuladas), y la mejora de B sobre A se interpreta como consecuencia del diseño.

---

## 3. Fuente 1: Olist Brazilian E-Commerce

### 3.1 Tablas

| Tabla | Registros | Campos clave | Rol en el TPI |
|---|---:|---|---|
| `olist_orders` | 99.441 | `order_id`, `order_status`, fechas de compra, despacho, entrega y promesa | Tabla central: estado y tiempos |
| `olist_order_items` | 112.650 | `order_id`, `product_id`, `seller_id`, `price`, `freight_value` | Costos de flete; vendedor de origen; peso para asignar el vehículo |
| `olist_customers` | 99.441 | `customer_id`, `customer_state`, `customer_zip_code_prefix` | Destino del envío |
| `olist_sellers` | 3.095 | `seller_id`, `seller_state`, `seller_zip_code_prefix` | Origen del envío |
| `olist_products` | 32.952 | `product_id`, `product_weight_g`, categoría | El peso determina el tipo de vehículo |
| `olist_order_reviews` | 99.224 | `order_id`, `review_score`, comentario | Satisfacción del cliente |
| `olist_order_payments` | 103.886 | `order_id`, `payment_type`, `payment_value` | Análisis financiero |
| `olist_geolocation` | 1.000.163 | prefijo de CEP, latitud, longitud | Distancias geográficas |
| `product_category_name_translation` | 71 | categoría en portugués e inglés | Traducción de categorías |

### 3.2 Problemas de calidad conocidos del dataset

| Problema | Magnitud | Tratamiento |
|---|---|---|
| Coordenadas fuera de Brasil | 42 de 1.000.163 (0,004 %) | Sin restricción geográfica en la base; se filtran en la preparación de datos |
| Productos con peso 0 o nulo | 4 con peso 0 y 3 nulos | La base admite 0 y NULL; se imputa con la mediana de la categoría |
| `review_id` duplicados | 814 | Clave interna `review_pk`; no se usa `review_id` para unir |
| Órdenes `delivered` sin fecha de entrega | 8 | Se excluyen del dataset analítico |
| Ítems que apuntan a productos inexistentes | 0 | La base incluye un producto auxiliar (`unknown_product_placeholder`) para preservar la integridad referencial; ningún ítem lo usa |

---

## 4. Fuente 2: flota logística sintética

### 4.1 Cómo se genera

`scripts/generate_fleet_dataset.py` produce las cinco tablas a partir de los datos reales de Olist.

1. **Se deriva de datos reales lo que existe en Olist:**
   - `distance_km`: distancia haversine entre el vendedor y el cliente (centroides de código postal de Olist) por un factor de ruta de 1,15 a 1,35.
   - `delivery_status`: `delayed` si Olist entregó después de la fecha prometida.
   - `eta_variation_hours`: horas reales de tránsito menos las esperadas para ese estado de destino y quintil de distancia, acotadas a [−168, 336] h.
2. **Se simula, condicionado a señales reales, lo que no existe en Olist** (tráfico, clima, riesgo de ruta, conductor, incidentes y mantenimiento) con una **cópula gaussiana**: cada variable se construye a partir de señales reales estandarizadas más ruido y se mapea por cuantiles a la distribución empírica de Kaggle, de modo que las marginales son exactamente las de Kaggle y solo cambia la dependencia con la realidad. La fuerza de cada vínculo es un parámetro explícito.
3. **Estructura coherente.** Hay un conductor por vehículo activo, la licencia habilita el tipo de vehículo, el conductor de la entrega maneja el vehículo de la entrega y los vehículos en baja no reciben entregas. El mantenimiento se genera después de las entregas, a partir de los kilómetros acumulados (preventivo por kilómetros o cada seis meses; correctivo con una probabilidad creciente con la edad, el uso y los kilómetros desde el último preventivo), de modo que su estacionalidad emerge del volumen de órdenes. Los incidentes tienen una probabilidad creciente con la demora real, el tráfico, el clima, el riesgo, la edad del vehículo y los días desde el último mantenimiento.

**Parámetros de efecto**

| Variable | Pesos de las señales en el latente |
|---|---|
| Tráfico | demora 0,25 · residuo de tránsito 0,15 · carga mensual 0,25 · urbanización del destino 0,20 |
| Clima | demora 0,25 · residuo de tránsito 0,10 · estación lluviosa de la macrorregión 0,40 |
| Riesgo de ruta | demora 0,30 · distancia 0,25 · lejanía del destino 0,20 |
| Conductor | `BEHAVIOR_BETA` = 0,4 y `FATIGUE_BETA` = 0,5: sesgan la asignación de las entregas tardías |
| Incidentes | tasa global 3,7 %; coeficientes: demora 1,6 · tráfico 0,35 · clima 0,30 · riesgo 0,25 · edad 0,20 · días desde el mantenimiento 0,25 |
| Mantenimiento | probabilidad mensual base de correctivo 0,04 (tope 0,20) |

**Reproducibilidad.** `SEED = 42` con un único generador. El script imprime una validación (dependencia con la realidad, marginales contra Kaggle y coherencia estructural) y la guarda en `fleet_generation_log.txt`.

### 4.2 Tablas

#### `fleet_vehicles` — 100 vehículos (95 activos, 5 en baja)

| Campo | Tipo | Descripción |
|---|---|---|
| `vehicle_id` | INT | PK |
| `plate` | CHAR(8) | Patente `AAA-9999`, única |
| `type` | VARCHAR | `moto` (24), `van` (53) o `truck` (23), según el mix de pesos de Olist |
| `brand`, `model` | VARCHAR | Marcas y modelos del mercado brasileño |
| `year` | SMALLINT | 2010–2016 |
| `capacity_kg` | SMALLINT | moto 30, van 500, truck 5000 |
| `fuel_type` | VARCHAR | flex/gasolina (motos), flex/diesel/gas natural (vans), diesel (trucks) |
| `fuel_consumption_rate_lh` | NUMERIC | Marginal de Kaggle, escalada por tipo |
| `status` | VARCHAR | `activo` (95) o `baja` (5); las bajas no reciben entregas |

#### `fleet_drivers` — 95 conductores (uno por vehículo activo)

| Campo | Tipo | Descripción |
|---|---|---|
| `driver_id` | INT | PK |
| `name` | VARCHAR | Nombre sintético |
| `license_type` | CHAR(1) | A (moto), B (van) o E (truck), coherente con el vehículo |
| `hire_date` | DATE | 2010 a 2016-08, anterior al inicio de Olist |
| `region_assigned` | CHAR(2) | Estado de reparto (estado de destino en el que opera) |
| `vehicle_id` | INT | FK a `fleet_vehicles`; único en los datos (1:1) |
| `driver_behavior_score` | NUMERIC | 0 a 1, marginal de Kaggle; sesga la asignación de entregas tardías |
| `fatigue_score_avg` | NUMERIC | 0 a 1, marginal de Kaggle; sesga la asignación de entregas tardías |

#### `fleet_deliveries` — 96.470 registros (tabla de vinculación)

| Campo | Tipo | Descripción |
|---|---|---|
| `delivery_id` | INT | PK |
| `order_id` | VARCHAR | FK a `olist_orders`, única: clave de vinculación entre fuentes |
| `vehicle_id` | INT | FK a `fleet_vehicles`; asignado según el peso del primer ítem (moto < 300 g, van < 2000 g, truck ≥ 2000 g) |
| `driver_id` | INT | FK a `fleet_drivers`; conductor del estado de destino y del tipo de vehículo requerido |
| `pickup_date`, `carrier_pickup_date`, `delivery_date` | TIMESTAMP | Fechas de compra, despacho y entrega, tomadas de Olist |
| `distance_km` | NUMERIC | Derivada de datos reales (ver 4.1); rango 5–6000 km |
| `route_state` | CHAR(2) | Estado de origen (`seller_state`) |
| `delivery_status` | VARCHAR | Derivada de datos reales: `delayed` si la entrega superó la fecha prometida (8,1 %) |
| `eta_variation_hours` | NUMERIC | Derivada de datos reales; acotada a [−168, 336] h (6,4 % de los valores en los límites): no se usa como variable objetivo |
| `loading_unloading_time_h` | NUMERIC | Marginal de Kaggle, escalada por tipo de vehículo y peso; sin vínculo con la demora (variable de control) |
| `route_risk_level` | NUMERIC | Simulada, 0 a 10 |
| `traffic_congestion_level` | NUMERIC | Simulada, 0 a 10 |
| `weather_condition_severity` | NUMERIC | Simulada, 0 a 1 |

Distribución: 88.644 entregas a tiempo (91,9 %) y 7.826 demoradas (8,1 %).

#### `fleet_maintenance` — 802 registros (547 preventivos, 255 correctivos)

| Campo | Descripción |
|---|---|
| `maintenance_id` | PK |
| `vehicle_id` | FK a `fleet_vehicles` |
| `date` | Entre 2016-09 y 2018-10 |
| `type` | `preventivo` (68,2 %) o `correctivo` (31,8 %) |
| `component` | Componente intervenido (aceite, frenos, motor, transmisión, etc.) |
| `cost_brl` | Costo por tipo de vehículo y de mantenimiento (promedio: correctivo R$ 2.080, preventivo R$ 321) |
| `downtime_hours` | Preventivo 1–6 h; correctivo 4–48 h, creciente con la edad (promedio correctivo: 30,9 h) |
| `mileage_at_service` | Kilometraje acumulado a partir de las entregas del vehículo |

#### `fleet_incidents` — 3.531 registros (19,2 % de las entregas tardías y 2,3 % de las puntuales)

| Campo | Descripción |
|---|---|
| `incident_id` | PK |
| `vehicle_id` | FK a `fleet_vehicles` (el de la entrega) |
| `date` | Entre el despacho y la entrega del viaje |
| `type` | `retraso_trafico`, `condicion_climatica`, `averia`, `falla_mecanica_menor` o `accidente`, con probabilidades que dependen del tráfico, el clima, el riesgo, la edad y el mantenimiento |
| `disruption_likelihood` | 0 a 1, marginal de Kaggle asociada al impacto |
| `impact_on_delivery_h` | accidente 8–48 h; avería 4–24 h; clima 2–12 h; tráfico 1–6 h; falla menor 1–4 h (la mitad en entregas puntuales) |
| `order_id` | FK a `olist_orders`, nullable |

---

## 5. Estructura de la base de datos

Base `olist_logistics_db` en PostgreSQL: 14 tablas, con 41 índices definidos en el DDL (20 de Olist y 21 de flota) más 14 índices adicionales (`sql/05_indices.sql`).

### 5.1 Relaciones principales

| Tabla | Campo | Referencia | Cardinalidad |
|---|---|---|---|
| `olist_orders` | `customer_id` | `olist_customers` | N:1 |
| `olist_order_items` | `order_id`, `product_id`, `seller_id` | `olist_orders`, `olist_products`, `olist_sellers` | N:1; PK compuesta (`order_id`, `order_item_id`) |
| `olist_order_reviews` | `order_id` | `olist_orders` | N:1; PK `review_pk` |
| `olist_order_payments` | `order_id` | `olist_orders` | N:1; PK compuesta (`order_id`, `payment_sequential`) |
| `fleet_deliveries` | `order_id` | `olist_orders` | 1:1 |
| `fleet_deliveries` | `vehicle_id` | `fleet_vehicles` | N:1 |
| `fleet_deliveries` | `driver_id` | `fleet_drivers` | N:1 |
| `fleet_drivers` | `vehicle_id` | `fleet_vehicles` | 1:1 en los datos |
| `fleet_maintenance` | `vehicle_id` | `fleet_vehicles` | N:1 |
| `fleet_incidents` | `vehicle_id` | `fleet_vehicles` | N:1 |
| `fleet_incidents` | `order_id` | `olist_orders` | N:1, nullable |

`olist_geolocation` se une por prefijo de código postal con `olist_customers` y `olist_sellers`, sin clave foránea.

### 5.2 Diagrama

```
 OLIST (real)                                                     FLOTA (sintética)
 ────────────                                                     ─────────────────
 olist_customers ◄─── olist_orders ───► olist_order_items ───► olist_products
                        │   │   │                    └───────► olist_sellers
                        │   │   └──► olist_order_reviews
                        │   └──────► olist_order_payments
                        │
                        ├── order_id (1:1) ──► fleet_deliveries ──► fleet_vehicles ◄── fleet_drivers (1:1)
                        │                            │                  ▲  ▲
                        │                            └─ driver_id ──────┼──┴──► fleet_drivers
                        │                                               │
                        └── order_id (nullable) ──► fleet_incidents ────┤
                                                    fleet_maintenance ──┘

 olist_geolocation: por prefijo de CEP (clientes y vendedores), sin clave foránea
```

---

## 6. Preguntas analíticas

Cada pregunta se responde con una consulta SQL (`sql/04_q*_explain.sql`). Los hallazgos citados provienen del análisis exploratorio de la Etapa 2 sobre el dataset analítico.

### Q1 — Factores de demora por estado y tipo de vehículo
**Pregunta:** ¿cuáles son los principales factores operativos de la flota asociados a las entregas demoradas, por estado de Brasil?
**Tablas:** `olist_orders`, `olist_customers`, `fleet_deliveries`, `fleet_vehicles`, `fleet_drivers`. **Resultado:** 80 combinaciones estado × tipo de vehículo con al menos 10 entregas (entregas, demoradas, porcentaje, variación de ETA, riesgo, comportamiento del conductor, distancia, tráfico y clima promedios).
**Hallazgos:** la demora real se concentra por destino: BA 14,0 % y RJ 13,5 %, frente a SP 5,9 %, MG 5,6 % y PR 5,0 %. Por tipo de vehículo es de 7,4 % (moto), 8,1 % (van) y 8,9 % (truck): diferencia despreciable, porque el tipo se asigna por peso. El tráfico promedio es 3,4 puntos mayor en las entregas demoradas (escala 0–10), por construcción del simulador.

### Q2 — Comportamiento del conductor y satisfacción
**Pregunta:** ¿existe relación entre el `driver_behavior_score` de un conductor y el `review_score` promedio de sus entregas?
**Tablas:** `fleet_drivers`, `fleet_deliveries`, `olist_order_reviews`. **Resultado:** 95 filas, una por conductor, con perfil alto, medio o bajo.
**Hallazgos:** por conductor, el score se asocia negativamente con la tasa de demora (rho = −0,43) y positivamente con la reseña (rho = +0,25), por construcción: el simulador asigna más entregas tardías a los conductores de menor score y la reseña lo hereda a través de la demora. Por entrega el efecto es débil (rho = −0,06). Los conductores tienen entre 498 y 2.166 entregas.

### Q3 — Estacionalidad de los mantenimientos y demoras mensuales
**Pregunta:** ¿en qué meses se concentran más los mantenimientos correctivos y coincide con el pico de demoras?
**Tablas:** `fleet_maintenance`, `olist_orders`, `fleet_deliveries`. **Resultado:** 26 filas (año y mes con mantenimientos).
**Hallazgos:** los picos reales de demora son noviembre de 2017 (14,3 %), febrero de 2018 (16,0 %) y marzo de 2018 (21,4 %), y acompañan el volumen mensual de órdenes (rho = +0,68). Los correctivos correlacionan con la demora mensual (+0,58) solo a través del volumen: por cada 1.000 entregas la correlación es −0,09, porque en el simulador siguen el uso de los vehículos.
**Performance:** esta consulta hace *spill* a disco (786 bloques, unos 6 MB) con el `work_mem` por defecto (4 MB).

### Q4 — Incidentes: impacto y cobertura
**Pregunta:** ¿qué tipos de incidente tienen mayor impacto en horas y qué proporción de las entregas demoradas cubren?
**Tablas:** `fleet_incidents`, `fleet_deliveries`, `fleet_vehicles`. **Resultado:** 5 filas, una por tipo de incidente, con total, impacto promedio y máximo, vehículos afectados y distribución por tipo de vehículo.
**Hallazgos:** hay 3.531 incidentes: el 19,2 % de las entregas tardías (1.499 de 7.826) y el 2,3 % de las puntuales (2.032 de 88.644) tienen al menos uno.

### Q5 — Costo de mantenimiento y rendimiento por tipo de vehículo
**Pregunta:** ¿cómo se relaciona el costo de mantenimiento con el rendimiento logístico de cada tipo de vehículo?
**Tablas:** `fleet_maintenance`, `fleet_vehicles`, `fleet_deliveries`. **Resultado:** 3 filas (moto, van, truck) con costo total y por entrega, tiempo de inactividad, porcentaje de entregas a tiempo y distancia.
**Hallazgos:** la tasa de entregas a tiempo es prácticamente igual entre tipos (moto 92,6 %, van 91,9 %, truck 91,1 %). El costo de mantenimiento responde a los rangos definidos en el generador. Tráfico y clima son iguales entre tipos de vehículo, por lo que no hay evidencia de que las motos sean más afectadas.

---

## 7. Performance de las consultas

Cada consulta se midió con `EXPLAIN (ANALYZE, BUFFERS)` sin y con los 14 índices de `05_indices.sql` (`performance/`). Detalle y metodología en `README.md` de esta etapa.

| Q | Plan principal | Índice usado | Buffers sin / con | Mediana de 3 repeticiones sin / con (ms) |
|---|---|---|---|---:|
| Q1 | Parallel Hash Join sobre 5 tablas | ninguno | 5.227 / 5.227 | 183,4 / 228,1 |
| Q2 | Parallel Hash Right Join | ninguno | 3.804 / 3.804 | 118,9 / 116,8 |
| Q3 | Hash Right Join con *spill* a disco | ninguno | 3.713 / 3.713 + 786 temporales | 234,9 / 182,3 |
| Q4 | Bitmap Heap Scan sobre `fleet_deliveries` | `idx_del_status` (del DDL) | 1.927 / 1.927 | 21,4 / 20,6 |
| Q5 | Merge Join sobre tablas de flota | ninguno | 1.893 / 1.893 | 65,4 / 66,6 |

**Conclusión.** Los índices adicionales no cambian ningún plan ni los buffers leídos; las diferencias de tiempo (de −22 % a +24 %) son ruido de medición y no efecto de los índices. Las consultas leen casi todas las filas de tablas pequeñas (97 % de las órdenes está entregado), por lo que el recorrido completo es la opción más barata. Solo Q4, que filtra el 8,1 % de las entregas, usa un índice, y ya viene del DDL. En Q3 el cuello de botella es la memoria, no el acceso a las filas. Los 14 índices ocupan unos 79 MB sin beneficio medido en estas consultas.

---

## 8. Indicadores (KPIs)

| # | KPI | Definición | Tablas | Naturaleza de los datos |
|---|---|---|---|---|
| 1 | Tasa de entrega a tiempo (OTD) | Órdenes entregadas hasta la fecha prometida / órdenes entregadas | `olist_orders` | Real |
| 2 | Demora promedio (días) | Promedio de (entrega − fecha prometida) en las órdenes tardías | `olist_orders` | Real |
| 3 | Variación de ETA promedio (h) | Mediana (o promedio) de `eta_variation_hours` por vehículo, región y período | `fleet_deliveries` | Derivada de datos reales (acotada) |
| 4 | Tasa de demora por tipo de vehículo | Entregas demoradas / entregas, por tipo de vehículo | `fleet_deliveries`, `fleet_vehicles` | Derivada de datos reales |
| 5 | Congestión promedio en demoradas | Promedio de `traffic_congestion_level` en entregas demoradas | `fleet_deliveries` | Simulada |
| 6 | Severidad climática en demoradas | Promedio de `weather_condition_severity` en entregas demoradas | `fleet_deliveries` | Simulada |
| 7 | Puntaje promedio de reseña | Promedio de `review_score` por período, estado y categoría | `olist_order_reviews` | Real |
| 8 | Porcentaje de reseñas de 1 o 2 estrellas | Reseñas con puntaje ≤ 2 / reseñas | `olist_order_reviews` | Real |
| 9 | Driver behavior score promedio | Promedio de `driver_behavior_score` por conductor y región | `fleet_drivers` | Simulada |
| 10 | Índice de fatiga promedio | Promedio de (1 − `fatigue_score_avg`) | `fleet_drivers` | Simulada |
| 11 | Ratio preventivo / correctivo | Mantenimientos preventivos / correctivos, por vehículo | `fleet_maintenance` | Simulada |
| 12 | Costo promedio del correctivo por tipo | Promedio de `cost_brl` de los correctivos por tipo de vehículo | `fleet_maintenance`, `fleet_vehicles` | Simulada |
| 13 | Tiempo de inactividad por mantenimiento | Promedio de `downtime_hours` por tipo de mantenimiento y mes | `fleet_maintenance` | Simulada |
| 14 | Tasa de incidentes por vehículo | Incidentes / entregas, por vehículo | `fleet_incidents`, `fleet_deliveries` | Simulada |
| 15 | Impacto promedio de incidentes | Promedio de `impact_on_delivery_h` por tipo de incidente | `fleet_incidents` | Simulada |
| 16 | Costo de flete por kilogramo | Promedio de `freight_value` / (`product_weight_g` / 1000) | `olist_order_items`, `olist_products` | Real |

Los KPIs de naturaleza simulada describen el sistema simulado; sus asociaciones con la demora están impuestas por el generador. Los de resultado y de satisfacción (1, 2, 7 y 8) y la tasa de demora por destino se calculan sobre datos reales y son los que sostienen las conclusiones del problema. Los conteos (incidentes, correctivos) se normalizan siempre por el volumen de entregas.

---

## 9. Plan de las cuatro etapas

| Etapa | Qué se produce |
|---|---|
| **1. Problema, datos y arquitectura** | Este documento; la base `olist_logistics_db` (14 tablas, ver sección 5); la flota sintética; cinco consultas con su análisis de plan de ejecución |
| **2. Preparación y análisis** | Diagnóstico de calidad de 52 chequeos; dataset analítico de una fila por orden entregada (vista lógica y materializada); análisis exploratorio; nuevo análisis del plan de ejecución |
| **3. Análisis inteligente y BI** | **Modelo 1 (regresión):** `dias_entrega_total`. **Modelo 2 (clasificación):** `demora_olist` (8,1 % de positivos, clase desbalanceada: AUC-PR y recall). Ridge, Random Forest y un árbol de decisión o regresión logística; validación temporal (entrenamiento hasta 2018-04, prueba desde 2018-05); predictores en dos conjuntos: **A** (variables reales conocidas al comprar: estados de origen y destino, distancia haversine, flete, peso, categoría, mes, volumen mensual y días prometidos) y **B** (A más las variables simuladas, incluidos `dias_desde_ult_mant`, tráfico, clima, riesgo y conductor). KPIs en `sql/kpis.sql` y reglas prescriptivas de priorización de destinos |
| **4. Dashboard** | Vista ejecutiva (KPIs y alertas), vista analítica (exploración por destino, período, vehículo y conductor, con filtros y drill-down) y vista de decisión (predicciones y recomendaciones), alimentado por el dataset analítico |

---

## 10. Alcance y limitaciones

- Las variables de flota excepto `distance_km`, `delivery_status` y `eta_variation_hours` son simuladas: los indicadores que las usan describen un escenario, no la operación real de Olist.
- `delivery_status` coincide con la demora real de Olist; el estado de la entrega y la demora son la misma definición.
- `eta_variation_hours` está acotada y no sirve como variable objetivo.
- Los datos reales cubren 2016-09 a 2018-08, con un régimen irregular (picos de demora en noviembre de 2017 y en febrero y marzo de 2018) que condiciona la validación temporal.
- Ocho órdenes `delivered` no tienen fecha de entrega y se excluyen del análisis.
- Olist se publica bajo CC BY-NC-SA 4.0: el uso es académico y no comercial.
