SET client_encoding = 'UTF8';
-- ============================================================
-- 04_q2_explain.sql
-- Q2: behavior_score vs review_score por conductor
-- Tablas: fleet_deliveries, fleet_drivers, olist_order_reviews
--
-- USO:
--   SIN indices (ejecutar ANTES de 05_indices.sql):
--     psql -U postgres -d olist_logistics_db -f 04_q2_explain.sql
--       > ..\performance\explain_sin_indices\q2_sin_idx.txt
--
--   CON indices (ejecutar DESPUES de 05_indices.sql):
--     psql -U postgres -d olist_logistics_db -f 04_q2_explain.sql
--       > ..\performance\explain_con_indices\q2_con_idx.txt
--
-- REQUISITO: activar track_io_timing para medir I/O real
--   SET track_io_timing = on;
-- ============================================================

-- Activar medicion de I/O (necesario para ver tiempos de lectura de disco/cache)
SET track_io_timing = on;

-- Limpiar cache de paginas de PostgreSQL para medir cold cache (opcional)
-- DISCARD ALL;  -- descomentar solo si se quiere medir cold start

EXPLAIN (
    ANALYZE,      -- ejecuta la consulta y mide tiempos reales
    BUFFERS,      -- muestra hits/misses de shared_buffers, lecturas de disco
    VERBOSE,      -- muestra columnas de output y schema de cada nodo
    SETTINGS,     -- muestra parametros de configuracion relevantes (work_mem, etc.)
    WAL,          -- muestra actividad WAL generada (escrituras)
    FORMAT TEXT   -- salida legible para guardar en .txt
)
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

-- ============================================================
-- CAMPOS CLAVE A REGISTRAR EN LA TABLA COMPARATIVA:
--
--  Tiempo total        -> 'Execution Time: X ms'  (ultima linea del plan)
--  Tiempo de planning  -> 'Planning Time: X ms'
--  Shared buffers hit  -> 'Buffers: shared hit=N'  (cache PostgreSQL, sin I/O)
--  Shared buffers read -> 'Buffers: shared read=N' (leido de disco)
--  I/O read time       -> 'I/O Timings: read=X ms' (requiere track_io_timing=on)
--  Filas estimadas     -> 'rows=N' en cada nodo (estimacion del planner)
--  Filas reales        -> 'actual rows=N' en cada nodo
--  Operacion principal -> primer nodo del plan (Seq Scan / Index Scan / Hash Join)
--  work_mem usado      -> visible en SETTINGS si se modifico
-- ============================================================
