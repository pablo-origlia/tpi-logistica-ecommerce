-- =====================================================================
-- ETAPA 2 · 05_refresh_y_mantenimiento.sql
-- Rutina de actualización del dataset analítico + auditoría de índices.
-- Ejecutar: psql -U postgres -d olist_logistics_db -f 05_refresh_y_mantenimiento.sql > ../docs/refresh_y_mantenimiento.txt
-- =====================================================================
\timing on

-- 1) REFRESH con más memoria SOLO para esta sesión (con work_mem = 16 MB la construcción hace
--    spill a disco: dos external merge sort).
SET work_mem = '64MB';

-- 2) CONCURRENTLY: no bloquea lecturas (dashboards, consultas) mientras se actualiza.
--    Requiere un índice UNIQUE (ux_mv_ds_order). El REFRESH común toma un lock exclusivo
--    y bloquea toda lectura mientras se actualiza (~6 s). Trade-off: CONCURRENTLY tarda más.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_dataset_analitico;
ANALYZE mv_dataset_analitico;

-- 3) Auditoría de índices (solo lectura): candidatos a revisión, ordenados por tamaño.
--    OJO: idx_scan es acumulado desde el último reset de estadísticas. Un índice sin uso aquí
--    puede servir a una consulta de Etapa 3/4 que todavía no corrió. NO borrar sin revisarlo.
SELECT s.relname AS tabla, s.indexrelname AS indice,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS tamano, s.idx_scan
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
ORDER BY pg_relation_size(s.indexrelid) DESC;

-- 4) Proporción índices / tabla (¿hay sobre-indexación?)
SELECT c.relname AS tabla,
       pg_size_pretty(pg_relation_size(c.oid))                          AS tabla_heap,
       pg_size_pretty(pg_indexes_size(c.oid))                           AS indices,
       ROUND(pg_indexes_size(c.oid)::numeric / NULLIF(pg_relation_size(c.oid),0), 2) AS ratio_idx_tabla
FROM pg_class c
WHERE c.relkind IN ('r','m') AND c.relnamespace = 'public'::regnamespace
ORDER BY pg_indexes_size(c.oid) DESC
LIMIT 10;
