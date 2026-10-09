SET client_encoding = 'UTF8';
-- ============================================================
-- 04_q4_explain.sql
-- Q4: Tipos de incidente: impacto en horas y cobertura
-- Tablas: fleet_incidents, fleet_deliveries, fleet_vehicles
--
-- USO:
--   SIN indices (ejecutar ANTES de 05_indices.sql):
--     psql -U postgres -d olist_logistics_db -f 04_q4_explain.sql
--       > ..\performance\explain_sin_indices\q4_sin_idx.txt
--
--   CON indices (ejecutar DESPUES de 05_indices.sql):
--     psql -U postgres -d olist_logistics_db -f 04_q4_explain.sql
--       > ..\performance\explain_con_indices\q4_con_idx.txt
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
