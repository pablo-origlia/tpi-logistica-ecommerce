SET client_encoding = 'UTF8';
-- ============================================================
-- 04_q1_explain.sql
-- Q1: Factores de demora por estado y tipo de vehiculo
-- Tablas: olist_orders, olist_customers, fleet_deliveries, fleet_vehicles, fleet_drivers
--
-- USO:
--   SIN indices (ejecutar ANTES de 05_indices.sql):
--     psql -U postgres -d olist_logistics_db -f 04_q1_explain.sql
--       > ..\performance\explain_sin_indices\q1_sin_idx.txt
--
--   CON indices (ejecutar DESPUES de 05_indices.sql):
--     psql -U postgres -d olist_logistics_db -f 04_q1_explain.sql
--       > ..\performance\explain_con_indices\q1_con_idx.txt
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
