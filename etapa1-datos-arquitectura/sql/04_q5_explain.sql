SET client_encoding = 'UTF8';
-- 04_q5_explain.sql
-- Q5: Costo de mantenimiento vs rendimiento por tipo de vehiculo
-- Ejecutar: psql -U postgres -d olist_logistics_db -f 04_q5_explain.sql
--   SIN indices: > ..\performance\explain_sin_indices\q5_sin_idx.txt
--   CON indices: > ..\performance\explain_con_indices\q5_con_idx.txt
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
