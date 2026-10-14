SET client_encoding = 'UTF8';
-- =============================================================
-- 05_indices.sql
-- Indices adicionales para las consultas analiticas  -  Etapa 1
-- Base de datos: olist_logistics_db (PostgreSQL 15+)
-- Proyecto TPI  -  Analisis de Datos Masivos, UCASAL 2026
-- =============================================================
-- CUANDO EJECUTAR:
--   Despues de 03_import_data.sql y de las consultas "sin indices" del
--   EXPLAIN ANALYZE, y ANTES de las consultas "con indices".
--   Lo hace run_pipeline.ps1.
--
-- QUE HAY ACA vs. QUE YA EXISTE EN EL DDL:
--   El DDL (01 y 02) creo indices simples sobre columnas de JOIN
--   y filtro individual (FK, status, timestamps).
--   Este script agrega indices COMPUESTOS y FUNCIONALES disenados
--   para el patron de acceso de las 5 consultas (Q1 a Q5): filtros
--   combinados, agrupaciones por mes/ano, covering indexes para evitar
--   heap fetches e indices parciales sobre subconjuntos selectivos.
--   Que el planner los use o no es justamente lo que se mide: ver
--   performance/ y la seccion de performance del README de la etapa.
--
-- WORKFLOW DE MEDICION (lo ejecuta run_pipeline.ps1):
--   1. EXPLAIN ANALYZE de Q1-Q5 -> performance/explain_sin_indices/
--   2. Ejecutar este script (05_indices.sql)
--   3. EXPLAIN ANALYZE de Q1-Q5 -> performance/explain_con_indices/
--   4. Comparar: tiempo, filas, Seq Scan vs Index Scan / Bitmap Scan
-- =============================================================


-- =============================================================
-- SECCION A  -  Indices para la Consulta 1
-- (estado x tipo_vehiculo, entregas demoradas por region)
-- =============================================================

-- A1. Covering index en olist_orders para el filtro WHERE + JOIN
--     Objetivo: que el planner obtenga customer_id y order_id directamente
--     desde el indice, sin leer la tabla principal (~99k filas).
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_ord_status_covering
    ON olist_orders (order_status)
    INCLUDE (order_id, customer_id)
    WHERE order_status = 'delivered';

COMMENT ON INDEX idx_ord_status_covering IS
    'Covering index parcial para Q1 y Q3. Evita heap fetch en olist_orders '
    'al filtrar por status=delivered. Incluye order_id y customer_id.';

-- A2. Indice compuesto en olist_customers para el JOIN + GROUP BY
--     El planner puede resolver customer_state directamente desde
--     el indice despues del JOIN sin acceder a la tabla.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_cust_id_state
    ON olist_customers (customer_id, customer_state);

COMMENT ON INDEX idx_cust_id_state IS
    'Covering index para Q1: resuelve el JOIN customer_id y la proyeccion '
    'de customer_state sin heap fetch en olist_customers.';

-- A3. Indice compuesto en fleet_deliveries para el JOIN + filtros combinados
--     Consulta 1 filtra por vehicle_id y agrupa por delivery_status.
--     INCLUDE con las metricas de trayecto y las covariables de trafico y clima.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_del_vehicle_status
    ON fleet_deliveries (vehicle_id, delivery_status)
    INCLUDE (eta_variation_hours, route_risk_level, driver_id, distance_km,
             traffic_congestion_level, weather_condition_severity);

-- A4. Indice sobre traffic_congestion_level para filtros y agregaciones
--     Q1: AVG(traffic_congestion_level) GROUP BY estado/tipo
--     Q3: AVG(traffic_congestion_level) GROUP BY anio/mes
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_del_traffic_status
    ON fleet_deliveries (traffic_congestion_level, delivery_status)
    INCLUDE (eta_variation_hours, weather_condition_severity);

COMMENT ON INDEX idx_del_traffic_status IS
    'Indice covering para Q1 y Q3: cubre traffic_congestion_level + delivery_status '
    'e incluye eta_variation_hours y weather_condition_severity. '
    'Permite comparar congestion promedio en entregas demoradas vs a tiempo.';

COMMENT ON INDEX idx_del_vehicle_status IS
    'Covering index para Q1 y Q5: cubre vehicle_id + delivery_status + '
    'metricas de trayecto sin heap fetch en fleet_deliveries.';


-- =============================================================
-- SECCION B  -  Indices para la Consulta 2
-- (behavior_score x review_score por conductor)
-- =============================================================

-- B1. Covering index en fleet_deliveries para el JOIN por driver_id
--     + proyeccion de delivery_status y eta_variation_hours.
--     Reemplaza el scan completo de fleet_deliveries en Q2.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_del_driver_covering
    ON fleet_deliveries (driver_id, delivery_status)
    INCLUDE (order_id, eta_variation_hours);

COMMENT ON INDEX idx_del_driver_covering IS
    'Covering index para Q2: cubre el JOIN por driver_id y proyecta '
    'delivery_status + order_id + eta_variation_hours sin heap fetch.';

-- B2. Covering index en olist_order_reviews para el JOIN por order_id
--     + proyeccion de review_score.
--     El DDL ya tiene idx_rev_order (simple). Este agrega review_score
--     como INCLUDE para evitar el heap fetch posterior.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_rev_order_score
    ON olist_order_reviews (order_id)
    INCLUDE (review_score);

COMMENT ON INDEX idx_rev_order_score IS
    'Covering index para Q2: resuelve el LEFT JOIN por order_id y '
    'proyecta review_score sin acceder al heap de olist_order_reviews.';


-- =============================================================
-- SECCION C  -  Indices para la Consulta 3
-- (mantenimientos correctivos por mes vs. demoras mensuales)
-- =============================================================

-- C1. Indice funcional en fleet_maintenance sobre (ano, mes, type)
--     El DDL tiene idx_mnt_month_type con EXTRACT, pero PostgreSQL
--     solo puede usarlo si la expresion del WHERE es identica.
--     Este indice cubre la combinacion completa del GROUP BY de Q3.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_mnt_year_month_type
    ON fleet_maintenance (
        CAST(EXTRACT(YEAR FROM date) AS INTEGER),
        CAST(EXTRACT(MONTH FROM date) AS INTEGER),
        type
    )
    INCLUDE (cost_brl, downtime_hours);

COMMENT ON INDEX idx_mnt_year_month_type IS
    'Indice funcional para Q3: cubre el GROUP BY (ano, mes, type) en '
    'fleet_maintenance e incluye cost_brl y downtime_hours. '
    'El planner puede resolver el aggregate sin heap fetch.';

-- C2. Indice funcional en olist_orders para el GROUP BY mensual de demoras
--     Q3 agrupa por EXTRACT(YEAR/MONTH FROM order_purchase_timestamp).
--     Sin este indice: Seq Scan sobre 99k filas + sort.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_ord_year_month_status
    ON olist_orders (
        CAST(EXTRACT(YEAR FROM order_purchase_timestamp) AS INTEGER),
        CAST(EXTRACT(MONTH FROM order_purchase_timestamp) AS INTEGER),
        order_status
    )
    INCLUDE (order_id);

COMMENT ON INDEX idx_ord_year_month_status IS
    'Indice funcional para Q3: cubre el GROUP BY temporal de olist_orders '
    'combinado con el filtro por order_status. Evita Seq Scan + Sort.';


-- =============================================================
-- SECCION D  -  Indices para la Consulta 4
-- (incidentes: tipo x impacto x vehiculo)
-- =============================================================

-- D1. Covering index en fleet_incidents para el GROUP BY por tipo
--     + proyeccion de impacto y disruption. Evita heap fetch sobre
--     la tabla de incidentes (~3.500 filas).
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_inc_type_covering
    ON fleet_incidents (type, vehicle_id)
    INCLUDE (impact_on_delivery_h, disruption_likelihood, order_id);

COMMENT ON INDEX idx_inc_type_covering IS
    'Covering index para Q4: cubre el GROUP BY por tipo e incluye '
    'las metricas de impacto sin heap fetch en fleet_incidents.';

-- D2. Indice parcial para el subconjunto de demoradas con incidente
--     La cobertura CTE de Q4 hace LEFT JOIN sobre delivery_status=delayed.
--     Este indice parcial en fleet_deliveries (~8% de las filas) apunta
--     a resolver ese JOIN sin recorrer las entregas on_time.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_del_delayed_order
    ON fleet_deliveries (order_id)
    WHERE delivery_status = 'delayed';

COMMENT ON INDEX idx_del_delayed_order IS
    'Indice parcial para Q4: solo sobre entregas demoradas. '
    'Agiliza el LEFT JOIN con fleet_incidents en la CTE de cobertura. '
    'Mas pequeno y selectivo que idx_del_order (general).';


-- =============================================================
-- SECCION E  -  Indices para la Consulta 5
-- (costo de mantenimiento vs. rendimiento por tipo de vehiculo)
-- =============================================================

-- E1. Covering index en fleet_maintenance para el GROUP BY por vehicle_id
--     agrupado por type de vehiculo. Q5 accede a vehicle_id + type de
--     fleet_vehicles (pequena, 100 filas) y luego agrega desde maintenance.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_mnt_vehicle_type_covering
    ON fleet_maintenance (vehicle_id, type)
    INCLUDE (cost_brl, downtime_hours);

COMMENT ON INDEX idx_mnt_vehicle_type_covering IS
    'Covering index para Q5: cubre el JOIN vehicle_id + filtro por '
    'type (preventivo/correctivo) e incluye cost_brl y downtime_hours. '
    'Evita heap fetch en fleet_maintenance para el aggregate de costos.';

-- E2. Covering index en fleet_deliveries para el GROUP BY por vehicle_id
--     Q5 necesita COUNT, AVG(eta_variation_hours), AVG(distance_km),
--     SUM(distance_km) agrupados por vehicle_id.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_del_vehicle_metrics
    ON fleet_deliveries (vehicle_id, delivery_status)
    INCLUDE (eta_variation_hours, distance_km);

COMMENT ON INDEX idx_del_vehicle_metrics IS
    'Covering index para Q5: cubre el GROUP BY vehicle_id + delivery_status '
    'e incluye las metricas de trayecto para el aggregate de rendimiento. '
    'Complementa idx_del_vehicle_status con foco en distancia y ETA.';


-- =============================================================
-- SECCION F  -  Indices para el dataset analitico (Etapa 2)
-- (el JOIN principal que genera el dataset analitico)
-- =============================================================
-- Estos indices no impactan en las consultas de Etapa 1; los usa la
-- vista del dataset analitico de la Etapa 2.

-- F1. Indice compuesto en fleet_deliveries para el JOIN principal
--     del dataset analitico: order_id + todas las metricas clave.
--     Objetivo: evitar el Seq Scan completo en la consulta de generacion del dataset.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_del_analytical_base
    ON fleet_deliveries (order_id, delivery_status)
    INCLUDE (
        vehicle_id, driver_id,
        eta_variation_hours, distance_km,
        route_risk_level, loading_unloading_time_h,
        pickup_date, delivery_date
    );

COMMENT ON INDEX idx_del_analytical_base IS
    'Covering index para la Etapa 2: cubre el JOIN principal '
    'order_id + proyecta todas las metricas del dataset analitico '
    'sin heap fetch en fleet_deliveries.';

-- F2. Indice en olist_order_items para el JOIN por order_id
--     + proyeccion de freight_value y product_id.
--     La PK de items es (order_id, order_item_id)  -  este indice
--     cubre solo order_id con las columnas analiticas relevantes.
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_items_order_analytical
    ON olist_order_items (order_id)
    INCLUDE (product_id, seller_id, freight_value, price);

COMMENT ON INDEX idx_items_order_analytical IS
    'Covering index para Etapa 2: resuelve el JOIN order_id en '
    'olist_order_items y proyecta freight_value + product_id '
    'sin heap fetch. Complementa la PK (order_id, order_item_id).';


-- =============================================================
-- VERIFICACION  -  ejecutar despues de crear los indices
-- =============================================================

-- Listar todos los indices de la base con su tamano en disco
SELECT
    schemaname                              AS esquema,
    tablename                               AS tabla,
    indexname                               AS indice,
    pg_size_pretty(pg_relation_size(
        quote_ident(schemaname) || '.' ||
        quote_ident(indexname)
    ))                                      AS tamanio,
    indexdef                                AS definicion
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;

-- Tamano total de indices vs. datos
SELECT
    pg_size_pretty(pg_total_relation_size('olist_orders'))          AS olist_orders_total,
    pg_size_pretty(pg_indexes_size('olist_orders'))                  AS olist_orders_indices,
    pg_size_pretty(pg_total_relation_size('fleet_deliveries'))       AS fleet_deliveries_total,
    pg_size_pretty(pg_indexes_size('fleet_deliveries'))              AS fleet_deliveries_indices;

-- La relacion tamano de datos / tamano de indices muestra el trade-off
-- entre espacio en disco, costo de escritura y velocidad de consulta.
