SET client_encoding = 'UTF8';
-- =============================================================
-- 04_consultas_analiticas.sql
-- Preguntas analiticas  -  Etapa 1
-- Base de datos: olist_logistics_db (PostgreSQL 15+)
-- Proyecto TPI  -  Analisis de Datos Masivos, UCASAL 2026
-- =============================================================
-- Cada consulta responde una pregunta analitica definida en la
-- propuesta. Para capturar el plan de ejecucion, anteponer:
--   EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) <consulta>;
-- y guardar la salida en performance/explain_sin_indices/
-- =============================================================


-- +-------------------------------------------------------------+
-- | CONSULTA 1                                                  |
-- | Cuales son los principales factores operativos de la flota |
-- | asociados a las entregas demoradas, por estado de Brasil?   |
-- +-------------------------------------------------------------+
-- Tablas: olist_orders, olist_customers, fleet_deliveries,
--         fleet_vehicles, fleet_drivers
-- Metricas registradas:
--   - Tiempo de ejecucion
--   - Filas procesadas vs retornadas (27 estados -> 27 filas)
--   - Tipo de JOIN (Hash Join vs Nested Loop)
--   - Uso de indices idx_ord_status, idx_del_status

SELECT
    c.customer_state                                    AS estado,
    fv.type                                             AS tipo_vehiculo,
    COUNT(fd.delivery_id)                               AS total_entregas,
    COUNT(fd.delivery_id)
        FILTER (WHERE fd.delivery_status = 'delayed')   AS entregas_demoradas,
    ROUND(
        COUNT(fd.delivery_id)
            FILTER (WHERE fd.delivery_status = 'delayed')
        * 100.0
        / NULLIF(COUNT(fd.delivery_id), 0),
    1)                                                  AS pct_demoradas,
    ROUND(AVG(fd.eta_variation_hours)::NUMERIC, 2)      AS eta_variacion_promedio_h,
    ROUND(AVG(fd.route_risk_level)::NUMERIC, 2)         AS riesgo_ruta_promedio,
    ROUND(AVG(fdr.driver_behavior_score)::NUMERIC, 3)   AS comportamiento_conductor_promedio,
    ROUND(AVG(fd.distance_km)::NUMERIC, 1)              AS distancia_promedio_km
FROM olist_orders         o
JOIN olist_customers      c   ON c.customer_id   = o.customer_id
JOIN fleet_deliveries     fd  ON fd.order_id     = o.order_id
JOIN fleet_vehicles       fv  ON fv.vehicle_id   = fd.vehicle_id
JOIN fleet_drivers        fdr ON fdr.driver_id   = fd.driver_id
WHERE o.order_status = 'delivered'
GROUP BY
    c.customer_state,
    fv.type
HAVING COUNT(fd.delivery_id) >= 10      -- excluir combinaciones con muy pocos datos
ORDER BY
    pct_demoradas DESC,
    total_entregas DESC;

-- Interpretacion esperada:
-- Estados del nordeste (BA, PE, CE) y tipo truck mostraran mayor % demorado.
-- La columna eta_variacion_promedio_h cuantifica el impacto en horas.


-- +-------------------------------------------------------------+
-- | CONSULTA 2                                                  |
-- | Existe relacion entre el driver_behavior_score de un       |
-- | conductor y el review_score promedio de sus entregas?       |
-- +-------------------------------------------------------------+
-- Tablas: fleet_deliveries, fleet_drivers, olist_order_reviews
-- Metricas registradas:
--   - Comparar tiempo con y sin idx_rev_order
--   - Filas: ~40 conductores -> 40 filas con review promedio
--   - Plan: esperamos Index Scan en olist_order_reviews

WITH conductor_performance AS (
    SELECT
        fdr.driver_id,
        fdr.name                                        AS conductor,
        fdr.region_assigned,
        fdr.driver_behavior_score,
        fdr.fatigue_score_avg,
        COUNT(fd.delivery_id)                           AS total_entregas,
        COUNT(fd.delivery_id)
            FILTER (WHERE fd.delivery_status = 'delayed') AS entregas_demoradas,
        ROUND(AVG(r.review_score)::NUMERIC, 2)          AS review_score_promedio,
        ROUND(AVG(fd.eta_variation_hours)::NUMERIC, 2)  AS eta_variation_promedio_h
    FROM fleet_drivers        fdr
    JOIN fleet_deliveries     fd  ON fd.driver_id  = fdr.driver_id
    LEFT JOIN olist_order_reviews r ON r.order_id  = fd.order_id
    GROUP BY
        fdr.driver_id,
        fdr.name,
        fdr.region_assigned,
        fdr.driver_behavior_score,
        fdr.fatigue_score_avg
    HAVING COUNT(fd.delivery_id) >= 5
)
SELECT
    conductor,
    region_assigned,
    ROUND(driver_behavior_score::NUMERIC, 3)    AS behavior_score,
    ROUND(fatigue_score_avg::NUMERIC, 3)        AS fatigue_score,
    total_entregas,
    entregas_demoradas,
    ROUND(
        entregas_demoradas * 100.0
        / NULLIF(total_entregas, 0),
    1)                                          AS pct_demoradas,
    review_score_promedio,
    eta_variation_promedio_h,
    -- Clasificacion manual para facilitar visualizacion en el dashboard
    CASE
        WHEN driver_behavior_score >= 0.7 THEN 'alto'
        WHEN driver_behavior_score >= 0.4 THEN 'medio'
        ELSE 'bajo'
    END                                         AS perfil_comportamiento
FROM conductor_performance
ORDER BY driver_behavior_score DESC;

-- Interpretacion esperada:
-- Correlacion negativa entre behavior_score y pct_demoradas.
-- Este resultado alimenta el KPI #7 (Driver behavior score promedio)
-- y el KPI #12 (Indice de eficiencia por conductor).


-- +-------------------------------------------------------------+
-- | CONSULTA 3                                                  |
-- | En que meses se concentran mas los mantenimientos          |
-- | correctivos y coincide con el pico de demoras en Olist?     |
-- +-------------------------------------------------------------+
-- Tablas: fleet_maintenance, fleet_vehicles, fleet_deliveries, olist_orders
-- Metricas registradas:
--   - Uso de EXTRACT  -  ver si el planner usa idx_mnt_month_type
--   - Comparar Seq Scan vs Index Scan en fleet_maintenance
--   - Filas: 36 filas (12 meses x 3 anos)

WITH mantenimiento_mensual AS (
    SELECT
        CAST(EXTRACT(YEAR FROM m.date) AS INTEGER)             AS anio,
        CAST(EXTRACT(MONTH FROM m.date) AS INTEGER)             AS mes,
        COUNT(*) FILTER (WHERE m.type = 'correctivo')   AS correctivos,
        COUNT(*) FILTER (WHERE m.type = 'preventivo')   AS preventivos,
        COUNT(*)                                        AS total_mantenimientos,
        ROUND(AVG(m.cost_brl)
            FILTER (WHERE m.type = 'correctivo')::NUMERIC, 2)
                                                        AS costo_correctivo_promedio,
        ROUND(AVG(m.downtime_hours)
            FILTER (WHERE m.type = 'correctivo')::NUMERIC, 1)
                                                        AS downtime_correctivo_promedio_h
    FROM fleet_maintenance m
    GROUP BY anio, mes
),
demoras_mensuales AS (
    SELECT
        CAST(EXTRACT(YEAR FROM o.order_purchase_timestamp) AS INTEGER)  AS anio,
        CAST(EXTRACT(MONTH FROM o.order_purchase_timestamp) AS INTEGER)  AS mes,
        COUNT(*)                                                  AS total_ordenes,
        COUNT(*) FILTER (WHERE fd.delivery_status = 'delayed')   AS ordenes_demoradas,
        ROUND(
            COUNT(*) FILTER (WHERE fd.delivery_status = 'delayed')
            * 100.0 / NULLIF(COUNT(*), 0),
        1)                                                        AS pct_demoradas
    FROM olist_orders    o
    JOIN fleet_deliveries fd ON fd.order_id = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY anio, mes
)
SELECT
    mm.anio,
    mm.mes,
    TO_CHAR(
        TO_DATE(mm.mes::TEXT, 'MM'), 'Month'
    )                                               AS nombre_mes,
    mm.correctivos,
    mm.preventivos,
    mm.total_mantenimientos,
    mm.costo_correctivo_promedio,
    mm.downtime_correctivo_promedio_h,
    dm.total_ordenes,
    dm.ordenes_demoradas,
    dm.pct_demoradas                               AS pct_ordenes_demoradas
FROM mantenimiento_mensual  mm
LEFT JOIN demoras_mensuales dm
    ON dm.anio = mm.anio AND dm.mes = mm.mes
ORDER BY mm.anio, mm.mes;

-- Interpretacion esperada:
-- Nov-Dic: pico de mantenimientos correctivos (weight x 1.5-1.6 en el script)
-- y coincidencia con mayor % de ordenes demoradas en Olist.
-- Valida el patron estacional y la hipotesis del problema.


-- +-------------------------------------------------------------+
-- | CONSULTA 4                                                  |
-- | Que tipos de incidente generan mayor impacto en horas      |
-- | de demora y que porcentaje de las demoradas tienen          |
-- | incidente registrado?                                       |
-- +-------------------------------------------------------------+
-- Tablas: fleet_incidents, fleet_deliveries, fleet_vehicles
-- Metricas registradas:
--   - Filas procesadas: todos los incidentes (~14.000) vs 5 filas resultado
--   - Uso de idx_inc_type e idx_inc_order
--   - LEFT JOIN: muestra que no toda demora tiene incidente

WITH resumen_incidentes AS (
    SELECT
        fi.type                                         AS tipo_incidente,
        COUNT(fi.incident_id)                           AS total_incidentes,
        ROUND(AVG(fi.impact_on_delivery_h)::NUMERIC, 1) AS impacto_promedio_h,
        ROUND(MAX(fi.impact_on_delivery_h)::NUMERIC, 1) AS impacto_maximo_h,
        ROUND(AVG(fi.disruption_likelihood)::NUMERIC, 3) AS disruption_score_promedio,
        COUNT(DISTINCT fi.vehicle_id)                   AS vehiculos_afectados,
        -- Distribucion por tipo de vehiculo
        COUNT(fi.incident_id)
            FILTER (WHERE fv.type = 'moto')             AS incidentes_moto,
        COUNT(fi.incident_id)
            FILTER (WHERE fv.type = 'van')              AS incidentes_van,
        COUNT(fi.incident_id)
            FILTER (WHERE fv.type = 'truck')            AS incidentes_truck
    FROM fleet_incidents  fi
    JOIN fleet_vehicles   fv ON fv.vehicle_id = fi.vehicle_id
    GROUP BY fi.type
),
cobertura AS (
    -- Que % de las ordenes demoradas tienen incidente registrado?
    SELECT
        COUNT(DISTINCT fd.delivery_id)                  AS total_demoradas,
        COUNT(DISTINCT fi.order_id)                     AS demoradas_con_incidente,
        ROUND(
            COUNT(DISTINCT fi.order_id) * 100.0
            / NULLIF(COUNT(DISTINCT fd.delivery_id), 0),
        1)                                              AS pct_con_incidente
    FROM fleet_deliveries  fd
    LEFT JOIN fleet_incidents fi ON fi.order_id = fd.order_id
    WHERE fd.delivery_status = 'delayed'
)
SELECT
    ri.tipo_incidente,
    ri.total_incidentes,
    ROUND(ri.total_incidentes * 100.0
        / SUM(ri.total_incidentes) OVER (), 1)          AS pct_del_total,
    ri.impacto_promedio_h,
    ri.impacto_maximo_h,
    ri.disruption_score_promedio,
    ri.vehiculos_afectados,
    ri.incidentes_moto,
    ri.incidentes_van,
    ri.incidentes_truck,
    -- Cobertura global (igual en todas las filas, para referencia)
    cv.total_demoradas,
    cv.demoradas_con_incidente,
    cv.pct_con_incidente
FROM resumen_incidentes ri
CROSS JOIN cobertura    cv
ORDER BY ri.impacto_promedio_h DESC;

-- Interpretacion esperada:
-- accidente: mayor impacto promedio (8-48h)
-- retraso_trafico: mas frecuente (40% de los incidentes)
-- pct_con_incidente ~ 15% (por diseno del script)


-- +-------------------------------------------------------------+
-- | CONSULTA 5                                                  |
-- | El costo de mantenimiento correctivo por tipo de vehiculo  |
-- | se justifica con el rendimiento logistico de cada tipo?     |
-- +-------------------------------------------------------------+
-- Tablas: fleet_maintenance, fleet_vehicles, fleet_deliveries
-- Metricas registradas:
--   - JOIN entre 3 tablas propias de la flota: medir costo
--   - Comparar con consulta 1 que agrega Olist: diferencia de tiempo
--   - Filas: 3 filas (una por tipo de vehiculo)
--   - Plan: esperamos Hash Aggregate sobre Hash Join

WITH costo_mantenimiento AS (
    SELECT
        fv.type                                             AS tipo_vehiculo,
        COUNT(m.maintenance_id)                             AS total_mantenimientos,
        COUNT(m.maintenance_id)
            FILTER (WHERE m.type = 'correctivo')            AS total_correctivos,
        COUNT(m.maintenance_id)
            FILTER (WHERE m.type = 'preventivo')            AS total_preventivos,
        ROUND(
            COUNT(m.maintenance_id)
                FILTER (WHERE m.type = 'correctivo')
            * 100.0
            / NULLIF(COUNT(m.maintenance_id), 0),
        1)                                                  AS pct_correctivo,
        ROUND(SUM(m.cost_brl)::NUMERIC, 2)                  AS costo_total_brl,
        ROUND(AVG(m.cost_brl)
            FILTER (WHERE m.type = 'correctivo')::NUMERIC, 2)
                                                            AS costo_correctivo_promedio,
        ROUND(SUM(m.downtime_hours)::NUMERIC, 1)            AS downtime_total_h,
        ROUND(AVG(m.downtime_hours)
            FILTER (WHERE m.type = 'correctivo')::NUMERIC, 1)
                                                            AS downtime_correctivo_promedio_h
    FROM fleet_vehicles   fv
    JOIN fleet_maintenance m ON m.vehicle_id = fv.vehicle_id
    GROUP BY fv.type
),
rendimiento_entrega AS (
    SELECT
        fv.type                                             AS tipo_vehiculo,
        COUNT(fd.delivery_id)                               AS total_entregas,
        COUNT(fd.delivery_id)
            FILTER (WHERE fd.delivery_status = 'on_time')   AS entregas_on_time,
        ROUND(
            COUNT(fd.delivery_id)
                FILTER (WHERE fd.delivery_status = 'on_time')
            * 100.0
            / NULLIF(COUNT(fd.delivery_id), 0),
        1)                                                  AS pct_on_time,
        ROUND(AVG(fd.eta_variation_hours)::NUMERIC, 2)      AS eta_variation_promedio_h,
        ROUND(AVG(fd.distance_km)::NUMERIC, 1)              AS distancia_promedio_km,
        ROUND(SUM(fd.distance_km)::NUMERIC, 0)              AS distancia_total_km
    FROM fleet_vehicles   fv
    JOIN fleet_deliveries fd ON fd.vehicle_id = fv.vehicle_id
    GROUP BY fv.type
)
SELECT
    cm.tipo_vehiculo,
    -- Flota
    (SELECT COUNT(*) FROM fleet_vehicles fv2
     WHERE fv2.type = cm.tipo_vehiculo)                     AS unidades_en_flota,
    -- Costos
    cm.total_mantenimientos,
    cm.pct_correctivo                                       AS pct_mantenimiento_correctivo,
    cm.costo_total_brl,
    cm.costo_correctivo_promedio,
    cm.downtime_total_h,
    cm.downtime_correctivo_promedio_h,
    -- Rendimiento
    re.total_entregas,
    re.pct_on_time,
    re.eta_variation_promedio_h,
    re.distancia_promedio_km,
    re.distancia_total_km,
    -- KPI compuesto: costo de mantenimiento por entrega realizada
    ROUND(cm.costo_total_brl
        / NULLIF(re.total_entregas, 0)::NUMERIC, 2)         AS costo_mant_por_entrega_brl,
    -- KPI compuesto: costo de mantenimiento por km recorrido
    ROUND(cm.costo_total_brl
        / NULLIF(re.distancia_total_km, 0)::NUMERIC, 4)     AS costo_mant_por_km_brl
FROM costo_mantenimiento  cm
JOIN rendimiento_entrega  re ON re.tipo_vehiculo = cm.tipo_vehiculo
ORDER BY cm.tipo_vehiculo;

-- Interpretacion esperada:
-- truck: mayor costo absoluto pero mayor capacidad y distancias mas largas.
-- moto: menor costo y mayor pct_on_time (rutas urbanas cortas).
-- El KPI costo_mant_por_entrega_brl permite comparacion justa entre tipos.


-- =============================================================
-- BLOQUE DE ANALISIS DE PERFORMANCE
-- Ejecutar cada consulta con EXPLAIN ANALYZE y guardar la salida
-- =============================================================

-- Instrucciones:
--   1. Copiar cada bloque EXPLAIN en psql o en pgAdmin.
--   2. Guardar la salida en performance/explain_sin_indices/
--      con el nombre: q1_sin_idx.txt, q2_sin_idx.txt, etc.
--   3. Despues de ejecutar 05_indices.sql, repetir y guardar
--      en performance/explain_con_indices/
--   4. Comparar: Seq Scan vs Index Scan, Rows, Actual Time.

-- Ejemplo para Consulta 1:
/*
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    c.customer_state,
    fv.type,
    COUNT(fd.delivery_id),
    ...
*/

-- Campos a registrar en la presentacion (Etapa 1):
-- +--------------------------------------------------------------------------------+
-- | Consulta   | Tiempo (ms)  | Filas leidas | Operacion principal  | Indice usado |
-- +------------+--------------+--------------+----------------------+--------------+
-- | Q1 sin idx |              |              |                      |              |
-- | Q1 con idx |              |              |                      |              |
-- | Q2 sin idx |              |              |                      |              |
-- | Q2 con idx |              |              |                      |              |
-- | Q3 sin idx |              |              |                      |              |
-- | Q3 con idx |              |              |                      |              |
-- | Q4 sin idx |              |              |                      |              |
-- | Q4 con idx |              |              |                      |              |
-- | Q5 sin idx |              |              |                      |              |
-- | Q5 con idx |              |              |                      |              |
-- +--------------------------------------------------------------------------------+
