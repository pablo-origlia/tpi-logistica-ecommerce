-- =====================================================================
-- ETAPA 2 · 04_explain_etapa2.sql
-- Nuevo análisis del plan de ejecución: ¿cuánto cuesta construir y consumir el dataset analítico?
--   A) Vista lógica: agregado por estado (recalcula todos los JOIN en cada consulta)
--   B) Vista materializada: el mismo agregado
--   C) Vista lógica: consulta selectiva (1 estado, 1 mes)
--   D) Vista materializada: la misma consulta selectiva (usa índices)
--   E) Costo de construir el dataset completo (lo que paga cada REFRESH)
--   E2) REFRESH real de la materializada
--   F) Espacio ocupado   G) Uso de los índices
-- Ejecutar: psql -U postgres -d olist_logistics_db -f 04_explain_etapa2.sql > ../docs/explain_etapa2.txt
-- Requiere 02_vistas_analiticas.sql. Las mediciones varían ±20 % entre corridas (caché y carga de la máquina):
-- se comparan planes y buffers, no milisegundos sueltos.
-- =====================================================================
\timing on
SET max_parallel_workers_per_gather = 2;
SET work_mem = '16MB';           -- por encima del valor por defecto (4 MB) de las consultas de la Etapa 1

\echo '=== A) Vista lógica: agregado por estado de destino ==='
EXPLAIN (ANALYZE, BUFFERS, VERBOSE OFF, COSTS ON, TIMING ON)
SELECT estado_destino, COUNT(*) n, AVG(demora_olist::INT) tasa_demora
FROM vw_dataset_analitico GROUP BY 1;

\echo '=== B) Materializada: mismo agregado ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT estado_destino, COUNT(*) n, AVG(demora_olist::INT) tasa_demora
FROM mv_dataset_analitico GROUP BY 1;

\echo '=== C) Vista lógica: filtro selectivo (SP, un mes) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, review_score, eta_variation_hours
FROM vw_dataset_analitico
WHERE estado_destino = 'SP' AND mes_compra = DATE '2017-11-01';

\echo '=== D) Materializada: filtro selectivo (SP, un mes) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, review_score, eta_variation_hours
FROM mv_dataset_analitico
WHERE estado_destino = 'SP' AND mes_compra = DATE '2017-11-01';

\echo '=== E) Costo de construir el dataset completo (lo que paga cada REFRESH) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM vw_dataset_analitico;

\echo '=== E2) REFRESH real (ver tiempo en \timing) ==='
REFRESH MATERIALIZED VIEW mv_dataset_analitico;

\echo '=== F) Espacio ocupado ==='
SELECT relname,
       pg_size_pretty(pg_total_relation_size(oid)) AS tamano_total,
       pg_size_pretty(pg_relation_size(oid))       AS tamano_tabla
FROM pg_class
WHERE relname IN ('mv_dataset_analitico','mv_geo_zip','fleet_deliveries','olist_orders','olist_order_items','olist_geolocation')
ORDER BY pg_total_relation_size(oid) DESC;

\echo '=== G) Uso de los índices (idx_scan acumulado) ==='
SELECT relname AS tabla, indexrelname AS indice, idx_scan, idx_tup_read
FROM pg_stat_user_indexes
WHERE schemaname='public'
ORDER BY idx_scan DESC;
