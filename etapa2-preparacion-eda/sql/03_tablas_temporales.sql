-- =====================================================================
-- ETAPA 2 · 03_tablas_temporales.sql
-- Tablas temporales para el EDA. En PostgreSQL se usa CREATE TEMP TABLE
-- (equivalente a #tabla de SQL Server): viven solo en la sesión.
-- Ejecutar en una sola sesión psql:
--   psql -U postgres -d olist_logistics_db -f 03_tablas_temporales.sql > ../docs/tablas_temporales.txt
-- Requiere mv_dataset_analitico (02_vistas_analiticas.sql).
-- =====================================================================
DROP TABLE IF EXISTS tmp_percentiles;
DROP TABLE IF EXISTS tmp_outliers_iqr;
DROP TABLE IF EXISTS tmp_resumen_segmento;

-- 1) Percentiles de las variables numéricas clave
CREATE TEMP TABLE tmp_percentiles AS
SELECT v.variable,
       COUNT(*)                                                        AS n,
       AVG(v.x)::NUMERIC(12,3)                                         AS media,
       STDDEV_SAMP(v.x)::NUMERIC(12,3)                                 AS desvio,
       MIN(v.x)::NUMERIC(12,3)                                         AS minimo,
       percentile_cont(0.01) WITHIN GROUP (ORDER BY v.x)::NUMERIC(12,3) AS p01,
       percentile_cont(0.25) WITHIN GROUP (ORDER BY v.x)::NUMERIC(12,3) AS p25,
       percentile_cont(0.50) WITHIN GROUP (ORDER BY v.x)::NUMERIC(12,3) AS mediana,
       percentile_cont(0.75) WITHIN GROUP (ORDER BY v.x)::NUMERIC(12,3) AS p75,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY v.x)::NUMERIC(12,3) AS p95,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY v.x)::NUMERIC(12,3) AS p99,
       MAX(v.x)::NUMERIC(12,3)                                         AS maximo
FROM mv_dataset_analitico a
CROSS JOIN LATERAL (VALUES
   ('dias_entrega_total',        a.dias_entrega_total),
   ('dias_demora_olist',         a.dias_demora_olist),
   ('eta_variation_hours',       a.eta_variation_hours),
   ('distance_km',               a.distance_km),
   ('distancia_haversine_km',    a.distancia_haversine_km),
   ('flete_total',               a.flete_total),
   ('peso_total_g',              a.peso_total_g),
   ('traffic_congestion_level',  a.traffic_congestion_level),
   ('weather_condition_severity',a.weather_condition_severity),
   ('route_risk_level',          a.route_risk_level)
) AS v(variable, x)
WHERE v.x IS NOT NULL
GROUP BY v.variable;

-- 2) Outliers por regla IQR (1.5·IQR) para variables continuas
CREATE TEMP TABLE tmp_outliers_iqr AS
WITH q AS (
  SELECT variable, p25 AS q1, p75 AS q3, (p75 - p25) AS iqr FROM tmp_percentiles
)
SELECT variable, q1, q3, iqr,
       (q1 - 1.5*iqr) AS limite_inf, (q3 + 1.5*iqr) AS limite_sup
FROM q;

-- 3) Resumen por segmento (tipo de vehículo × perfil de conductor)
CREATE TEMP TABLE tmp_resumen_segmento AS
SELECT a.tipo_vehiculo,
       CASE WHEN a.driver_behavior_score < 0.4 THEN 'bajo'
            WHEN a.driver_behavior_score < 0.7 THEN 'medio' ELSE 'alto' END AS perfil_conductor,
       COUNT(*)                                   AS entregas,
       AVG(a.demora_olist::INT)                   AS tasa_demora_olist,
       AVG(a.eta_variation_hours)                 AS eta_prom_h,
       AVG(a.review_score)                        AS review_prom
FROM mv_dataset_analitico a
GROUP BY 1,2;

SELECT * FROM tmp_percentiles ORDER BY variable;
SELECT * FROM tmp_outliers_iqr ORDER BY variable;
SELECT * FROM tmp_resumen_segmento ORDER BY tipo_vehiculo, perfil_conductor;
