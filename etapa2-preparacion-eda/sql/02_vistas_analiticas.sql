-- =====================================================================
-- ETAPA 2 · 02_vistas_analiticas.sql
-- Construye el DATASET ANALÍTICO a partir de la base operacional.
--
--   mv_geo_zip               centroide limpio por prefijo CEP (1 fila por zip)
--   vw_dataset_analitico     GRANO = 1 fila por orden entregada (vista lógica)
--   mv_dataset_analitico     misma consulta, materializada + indexada
--   vw_flota_mes_tipo        GRANO = mes × tipo de vehículo (mantenimiento/incidentes/demoras)
--   vw_conductor             GRANO = 1 fila por conductor
--
-- Ejecutar: psql -U postgres -d olist_logistics_db -f 02_vistas_analiticas.sql
-- Idempotente (DROP ... IF EXISTS).
-- =====================================================================

DROP MATERIALIZED VIEW IF EXISTS mv_dataset_analitico CASCADE;
DROP VIEW              IF EXISTS vw_dataset_analitico CASCADE;
DROP VIEW              IF EXISTS vw_flota_mes_tipo   CASCADE;
DROP VIEW              IF EXISTS vw_conductor        CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_geo_zip          CASCADE;

-- ---------------------------------------------------------------------
-- 1. Geolocalización: 1.000.163 filas -> 1 centroide por zip (sin outliers)
--    Se filtra por bounding box de Brasil. Se usa mediana (robusta a puntos mal geocodificados).
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_geo_zip AS
SELECT geolocation_zip_code_prefix                                           AS zip,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY geolocation_lat)::NUMERIC(9,6) AS lat,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY geolocation_lng)::NUMERIC(9,6) AS lng,
       COUNT(*)                                                              AS n_puntos
FROM olist_geolocation
WHERE geolocation_lat BETWEEN -34.0  AND 5.27
  AND geolocation_lng BETWEEN -73.99 AND -34.79
GROUP BY geolocation_zip_code_prefix;
CREATE UNIQUE INDEX ux_mv_geo_zip ON mv_geo_zip(zip);
ANALYZE mv_geo_zip;

-- ---------------------------------------------------------------------
-- 1b. Índice de soporte para dias_desde_ult_mant (LATERAL por vehículo y fecha).
--     La vista busca, por cada orden, el último mantenimiento de su vehículo anterior a la compra.
--     Sin este índice el planner recorre idx_mnt_date y descarta las filas de otros vehículos en cada búsqueda.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_mnt_vehicle_date ON fleet_maintenance (vehicle_id, date);
ANALYZE fleet_maintenance;

-- ---------------------------------------------------------------------
-- 2. Dataset analítico (1 fila por orden)
--    Decisiones de limpieza (ver docs/informe_calidad_datos.md):
--      · Solo órdenes 'delivered' con registro en fleet_deliveries (INNER JOIN)
--      · Excluye fechas imposibles (carrier > customer, purchase > carrier)
--      · Ítems/pagos/reseñas se AGREGAN a nivel orden (evita fan-out)
--      · Peso 0/NULL -> mediana de la categoría (fallback: mediana global)
-- ---------------------------------------------------------------------
CREATE VIEW vw_dataset_analitico AS
WITH
peso_mediana AS (          -- mediana de peso por categoría, solo pesos válidos
  SELECT product_category_name AS cat,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY product_weight_g) AS peso_med
  FROM olist_products
  WHERE product_weight_g > 0 AND product_category_name IS NOT NULL
  GROUP BY product_category_name
),
peso_global AS (
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY product_weight_g) AS peso_med
  FROM olist_products WHERE product_weight_g > 0
),
items_prod AS (            -- ítem + producto con peso corregido
  SELECT i.order_id, i.order_item_id, i.seller_id, i.price, i.freight_value, i.product_id,
         COALESCE(p.product_category_name, 'sin_categoria') AS categoria,
         (p.product_weight_g IS NULL OR p.product_weight_g = 0
          OR i.product_id = 'unknown_product_placeholder')   AS peso_imputado,
         CASE WHEN p.product_weight_g > 0 AND i.product_id <> 'unknown_product_placeholder'
              THEN p.product_weight_g
              ELSE COALESCE(pm.peso_med, (SELECT peso_med FROM peso_global)) END AS peso_g
  FROM olist_order_items i
  JOIN olist_products p USING (product_id)
  LEFT JOIN peso_mediana pm ON pm.cat = p.product_category_name
),
items_agg AS (
  SELECT order_id,
         COUNT(*)                         AS n_items,
         COUNT(DISTINCT seller_id)        AS n_vendedores,
         SUM(price)                       AS precio_total,
         SUM(freight_value)               AS flete_total,
         SUM(peso_g)                      AS peso_total_g,
         BOOL_OR(peso_imputado)           AS flag_peso_imputado,
         MAX(seller_id)    FILTER (WHERE order_item_id = 1) AS seller_id,
         MAX(categoria)    FILTER (WHERE order_item_id = 1) AS categoria_principal
  FROM items_prod
  GROUP BY order_id
),
rev_ult AS (               -- 1 reseña por orden: la más reciente
  SELECT DISTINCT ON (order_id)
         order_id, review_score, review_comment_message IS NOT NULL AS tiene_comentario
  FROM olist_order_reviews
  ORDER BY order_id, review_creation_date DESC NULLS LAST, review_pk DESC
),
rev_cnt AS (
  SELECT order_id, COUNT(*) AS n_resenas FROM olist_order_reviews GROUP BY order_id
),
pagos AS (
  SELECT order_id,
         SUM(payment_value)                                        AS pago_total,
         MAX(payment_installments)                                 AS cuotas_max,
         MAX(payment_type) FILTER (WHERE payment_sequential = 1)   AS metodo_pago
  FROM olist_order_payments
  GROUP BY order_id
)
SELECT
  -- identificación
  o.order_id,
  fd.delivery_id,
  o.order_purchase_timestamp                                     AS fecha_compra,
  DATE_TRUNC('month', o.order_purchase_timestamp)::DATE          AS mes_compra,
  EXTRACT(YEAR  FROM o.order_purchase_timestamp)::INT            AS anio,
  EXTRACT(MONTH FROM o.order_purchase_timestamp)::INT            AS mes,
  EXTRACT(ISODOW FROM o.order_purchase_timestamp)::INT           AS dia_semana,
  -- geografía
  s.seller_state                                                 AS estado_origen,
  c.customer_state                                               AS estado_destino,
  (s.seller_state = c.customer_state)                            AS mismo_estado,
  -- orden / producto
  ia.n_items, ia.n_vendedores, ia.categoria_principal,
  COALESCE(t.product_category_name_english,
           CASE ia.categoria_principal                       -- traducciones faltantes en Olist
                WHEN 'pc_gamer' THEN 'pc_gamer'
                WHEN 'portateis_cozinha_e_preparadores_de_alimentos' THEN 'portable_kitchen_food_preparers'
                WHEN 'unknown'  THEN 'sin_categoria'
                ELSE ia.categoria_principal END)                AS categoria_en,
  ia.precio_total, ia.flete_total, ia.peso_total_g, ia.flag_peso_imputado,
  ROUND(ia.flete_total / NULLIF(ia.precio_total,0), 4)           AS flete_sobre_precio,
  pg.pago_total, pg.cuotas_max,
  CASE WHEN pg.metodo_pago IN ('credit_card','boleto','voucher','debit_card')
       THEN pg.metodo_pago ELSE 'otro' END                       AS metodo_pago,
  -- flota
  v.type                                                         AS tipo_vehiculo,
  fd.vehicle_id, fd.driver_id,
  d.driver_behavior_score,
  d.fatigue_score_avg,
  ROUND(1 - d.fatigue_score_avg, 3)                              AS indice_fatiga,
  fd.distance_km,
  fd.route_risk_level, fd.traffic_congestion_level, fd.weather_condition_severity,
  fd.loading_unloading_time_h,
  fd.eta_variation_hours,                                        -- horas de tránsito vs esperadas (derivada de fechas reales; acotada)
  fd.delivery_status,                                            -- on_time / delayed: replica la demora real de Olist (demora_olist)
  -- tiempos reales (Olist)
  ROUND(EXTRACT(EPOCH FROM o.order_delivered_customer_date - o.order_purchase_timestamp)/86400, 2) AS dias_entrega_total,
  ROUND(EXTRACT(EPOCH FROM o.order_delivered_carrier_date  - o.order_purchase_timestamp)/86400, 2) AS dias_hasta_despacho,
  ROUND(EXTRACT(EPOCH FROM o.order_delivered_customer_date - o.order_delivered_carrier_date)/86400, 2) AS dias_transito,
  ROUND(EXTRACT(EPOCH FROM o.order_estimated_delivery_date - o.order_purchase_timestamp)/86400, 2) AS dias_prometidos,
  ROUND(EXTRACT(EPOCH FROM o.order_delivered_customer_date - o.order_estimated_delivery_date)/86400, 2) AS dias_demora_olist,
  (o.order_delivered_customer_date > o.order_estimated_delivery_date) AS demora_olist,         -- definición OLIST (real)
  -- distancia geodésica (haversine) entre centroides de zip vendedor→cliente
  ROUND((6371 * 2 * ASIN(SQRT(
      POWER(SIN(RADIANS(gc.lat - gs.lat) / 2), 2) +
      COS(RADIANS(gs.lat)) * COS(RADIANS(gc.lat)) *
      POWER(SIN(RADIANS(gc.lng - gs.lng) / 2), 2))))::NUMERIC, 1)  AS distancia_haversine_km,
  -- satisfacción
  rv.review_score, rv.tiene_comentario, COALESCE(rc.n_resenas,0) AS n_resenas,
  (rv.review_score <= 2)                                         AS resena_negativa,
  -- incidentes (de la flota) asociados a la orden
  COALESCE(inc.n_incidentes,0)                                   AS n_incidentes,
  COALESCE(inc.horas_impacto,0)                                  AS horas_impacto_incidentes,
  -- mantenimiento previo del vehículo (conocido al comprar; NULL = sin mantenimiento registrado antes)
  um.dias                                                        AS dias_desde_ult_mant
FROM olist_orders o
JOIN fleet_deliveries fd         ON fd.order_id = o.order_id                  -- 8 delivered sin fleet -> fuera
JOIN fleet_vehicles   v          ON v.vehicle_id = fd.vehicle_id
JOIN fleet_drivers    d          ON d.driver_id  = fd.driver_id
JOIN olist_customers  c          ON c.customer_id = o.customer_id
JOIN items_agg        ia         ON ia.order_id = o.order_id                  -- sin ítems -> fuera
JOIN olist_sellers    s          ON s.seller_id = ia.seller_id
LEFT JOIN product_category_name_translation t ON t.product_category_name = ia.categoria_principal
LEFT JOIN pagos       pg         ON pg.order_id = o.order_id
LEFT JOIN rev_ult     rv         ON rv.order_id = o.order_id
LEFT JOIN rev_cnt     rc         ON rc.order_id = o.order_id
LEFT JOIN mv_geo_zip  gc         ON gc.zip = c.customer_zip_code_prefix
LEFT JOIN mv_geo_zip  gs         ON gs.zip = s.seller_zip_code_prefix
LEFT JOIN LATERAL (
     SELECT COUNT(*) AS n_incidentes, SUM(impact_on_delivery_h) AS horas_impacto
     FROM fleet_incidents fi WHERE fi.order_id = o.order_id) inc ON TRUE
LEFT JOIN LATERAL (
     SELECT (o.order_purchase_timestamp::DATE - MAX(m.date)) AS dias
     FROM fleet_maintenance m
     WHERE m.vehicle_id = fd.vehicle_id
       AND m.date <= o.order_purchase_timestamp::DATE) um ON TRUE
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_delivered_carrier_date  IS NOT NULL
  AND o.order_delivered_carrier_date  <= o.order_delivered_customer_date
  AND o.order_purchase_timestamp      <= o.order_delivered_carrier_date;

COMMENT ON VIEW vw_dataset_analitico IS
 'Dataset analítico. 1 fila por orden entregada. demora_olist = demora real; las variables operativas de flota (tráfico, clima, riesgo, conductor, mantenimiento, incidentes) son simuladas.';

-- ---------------------------------------------------------------------
-- 3. Versión materializada (lo que consume Python y el dashboard)
-- ---------------------------------------------------------------------
-- ORDER BY: ordena físicamente las filas por mes y estado. Cada REFRESH vuelve a ejecutar la consulta,
-- así que el orden se conserva. Un filtro por mes y estado lee páginas contiguas en lugar de dispersas.
CREATE MATERIALIZED VIEW mv_dataset_analitico AS
SELECT * FROM vw_dataset_analitico
ORDER BY mes_compra, estado_destino, order_id;
CREATE UNIQUE INDEX ux_mv_ds_order      ON mv_dataset_analitico(order_id);
CREATE INDEX        ix_mv_ds_mes        ON mv_dataset_analitico(mes_compra);
CREATE INDEX        ix_mv_ds_tipo       ON mv_dataset_analitico(tipo_vehiculo);
CREATE INDEX        ix_mv_ds_destino    ON mv_dataset_analitico(estado_destino);
ANALYZE mv_dataset_analitico;

-- ---------------------------------------------------------------------
-- 4. Flota por mes × tipo de vehículo (series temporales / estacionalidad)
-- ---------------------------------------------------------------------
CREATE VIEW vw_flota_mes_tipo AS
WITH ent AS (
  SELECT mes_compra AS mes, tipo_vehiculo,
         COUNT(*)                               AS entregas,
         AVG(demora_olist::INT)::NUMERIC(5,4)   AS tasa_demora_olist,
         AVG(eta_variation_hours)               AS eta_var_prom_h,
         AVG(traffic_congestion_level)          AS congestion_prom,
         AVG(weather_condition_severity)        AS clima_prom,
         AVG(review_score)                      AS review_prom
  FROM mv_dataset_analitico GROUP BY 1,2
),
mnt AS (
  SELECT DATE_TRUNC('month', m.date)::DATE AS mes, v.type AS tipo_vehiculo,
         COUNT(*) FILTER (WHERE m.type='correctivo') AS mant_correctivos,
         COUNT(*) FILTER (WHERE m.type='preventivo') AS mant_preventivos,
         SUM(m.cost_brl)                              AS costo_mant_brl,
         SUM(m.downtime_hours)                        AS downtime_h
  FROM fleet_maintenance m JOIN fleet_vehicles v USING (vehicle_id)
  GROUP BY 1,2
),
inc AS (
  SELECT DATE_TRUNC('month', i.date)::DATE AS mes, v.type AS tipo_vehiculo,
         COUNT(*) AS incidentes, SUM(i.impact_on_delivery_h) AS horas_impacto
  FROM fleet_incidents i JOIN fleet_vehicles v USING (vehicle_id)
  GROUP BY 1,2
)
SELECT e.mes, e.tipo_vehiculo, e.entregas, e.tasa_demora_olist,
       e.eta_var_prom_h, e.congestion_prom, e.clima_prom, e.review_prom,
       COALESCE(m.mant_correctivos,0) AS mant_correctivos,
       COALESCE(m.mant_preventivos,0) AS mant_preventivos,
       COALESCE(m.costo_mant_brl,0)   AS costo_mant_brl,
       COALESCE(m.downtime_h,0)       AS downtime_h,
       COALESCE(i.incidentes,0)       AS incidentes,
       COALESCE(i.horas_impacto,0)    AS horas_impacto_incidentes
FROM ent e
LEFT JOIN mnt m USING (mes, tipo_vehiculo)
LEFT JOIN inc i USING (mes, tipo_vehiculo);

-- ---------------------------------------------------------------------
-- 5. Perfil por conductor
-- ---------------------------------------------------------------------
CREATE VIEW vw_conductor AS
-- 1 conductor = 1 vehículo (fleet_drivers.vehicle_id es el vehículo de todas sus entregas) y la licencia
-- habilita el tipo. vehiculos_distintos y tipos_vehiculo_distintos deben ser 1 (control de coherencia).
SELECT d.driver_id, d.region_assigned, d.license_type, d.vehicle_id, v.type AS tipo_vehiculo,
       d.driver_behavior_score, d.fatigue_score_avg,
       ROUND(1 - d.fatigue_score_avg, 3) AS indice_fatiga,
       CASE WHEN d.driver_behavior_score < 0.4 THEN 'bajo'
            WHEN d.driver_behavior_score < 0.7 THEN 'medio' ELSE 'alto' END AS perfil,
       COUNT(a.order_id)                          AS entregas,
       COUNT(DISTINCT a.vehicle_id)               AS vehiculos_distintos,
       COUNT(DISTINCT a.tipo_vehiculo)            AS tipos_vehiculo_distintos,
       AVG(a.demora_olist::INT)::NUMERIC(5,4)     AS tasa_demora_olist,
       AVG(a.review_score)                        AS review_prom
FROM fleet_drivers d
JOIN fleet_vehicles v ON v.vehicle_id = d.vehicle_id
LEFT JOIN mv_dataset_analitico a USING (driver_id)
GROUP BY d.driver_id, d.region_assigned, d.license_type, d.vehicle_id, v.type,
         d.driver_behavior_score, d.fatigue_score_avg;
