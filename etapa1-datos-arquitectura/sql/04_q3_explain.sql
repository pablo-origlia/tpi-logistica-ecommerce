SET client_encoding = 'UTF8';
-- 04_q3_explain.sql
-- Q3: Pico estacional de mantenimientos vs demoras (+ congestion promedio mensual)
-- Ejecutar: psql -U postgres -d olist_logistics_db -f 04_q3_explain.sql
--   > ..\performance\explain_sin_indices\q3_sin_idx.txt
-- (cambiar carpeta a con_indices despues de 05_indices.sql)
-- Requiere: SET track_io_timing = on
-- ============================================================

SET track_io_timing = on;

EXPLAIN (
    ANALYZE,
    BUFFERS,
    VERBOSE,
    SETTINGS,
    WAL,
    FORMAT TEXT
)
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
        1)                                                        AS pct_demoradas,
        -- Nuevos: contexto externo promedio por mes
        ROUND(AVG(fd.traffic_congestion_level)::NUMERIC, 2)      AS congestion_promedio,
        ROUND(AVG(fd.weather_condition_severity)::NUMERIC, 3)    AS clima_severidad_promedio
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
    dm.pct_demoradas                               AS pct_ordenes_demoradas,
    dm.congestion_promedio,
    dm.clima_severidad_promedio
FROM mantenimiento_mensual  mm
LEFT JOIN demoras_mensuales dm
    ON dm.anio = mm.anio AND dm.mes = mm.mes;
