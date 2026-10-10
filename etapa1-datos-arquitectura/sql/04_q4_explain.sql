SET client_encoding = 'UTF8';
-- 04_q4_explain.sql
-- Q4: Tipos de incidente: impacto en horas y cobertura
-- Ejecutar: psql -U postgres -d olist_logistics_db -f 04_q4_explain.sql
--   SIN indices: > ..\performance\explain_sin_indices\q4_sin_idx.txt
--   CON indices: > ..\performance\explain_con_indices\q4_con_idx.txt
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
