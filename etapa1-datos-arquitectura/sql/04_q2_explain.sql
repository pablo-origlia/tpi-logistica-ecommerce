SET client_encoding = 'UTF8';
-- 04_q2_explain.sql
-- Q2: behavior_score vs review_score por conductor
-- Ejecutar: psql -U postgres -d olist_logistics_db -f 04_q2_explain.sql
--   > ..\performance\explain_sin_indices\q2_sin_idx.txt
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
-- Este resultado alimenta el KPI #7 (Driver behavior score promedio);
