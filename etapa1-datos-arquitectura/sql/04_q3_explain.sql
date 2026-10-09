SET client_encoding = 'UTF8';
-- ============================================================
-- 04_q3_explain.sql
-- Q3: Pico estacional de mantenimientos correctivos vs demoras
-- Tablas: fleet_maintenance, fleet_deliveries, olist_orders
--
-- USO:
--   SIN indices (ejecutar ANTES de 05_indices.sql):
--     psql -U postgres -d olist_logistics_db -f 04_q3_explain.sql
--       > ..\performance\explain_sin_indices\q3_sin_idx.txt
--
--   CON indices (ejecutar DESPUES de 05_indices.sql):
--     psql -U postgres -d olist_logistics_db -f 04_q3_explain.sql
--       > ..\performance\explain_con_indices\q3_con_idx.txt
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
