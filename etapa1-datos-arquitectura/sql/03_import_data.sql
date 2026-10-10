SET client_encoding = 'UTF8';
-- =============================================================
-- 03_import_data.sql
-- Carga de datos: COPY desde CSV hacia las tablas de la BD
-- Base de datos: olist_logistics_db (PostgreSQL 15+)
-- Proyecto TPI — Analisis de Datos Masivos, UCASAL 2026
-- =============================================================
-- ANTES DE EJECUTAR:
--   1. Ajustar la variable :csv_path al directorio donde estan
--      los CSV (ver instrucciones abajo).
--   2. Ejecutar como superusuario o con permisos pg_read_server_files.
--   3. Los archivos deben estar accesibles desde el servidor PostgreSQL.
--
-- AJUSTE DE RUTA:
--   Opcion A — psql con variable:
--     psql -v csv_olist="C:/ruta/etapa1-datos-arquitectura/raw" \
--          -v csv_fleet="C:/ruta/etapa1-datos-arquitectura/fleet_synthetic" \
--          -d olist_logistics_db -f 03_import_data.sql
--
--   Opcion B — reemplazar :'csv_olist' y :'csv_fleet' con la ruta real.
--
-- NOTA: En Windows usar barras / no \ en las rutas dentro de COPY.
-- =============================================================

-- ─────────────────────────────────────────
-- Definición de rutas completas mediante psql
-- ─────────────────────────────────────────
\set file_geo    :csv_olist '/olist_geolocation_dataset.csv'
\set file_cust   :csv_olist '/olist_customers_dataset.csv'
\set file_sell   :csv_olist '/olist_sellers_dataset.csv'
\set file_prod   :csv_olist '/olist_products_dataset.csv'
\set file_trans  :csv_olist '/product_category_name_translation.csv'
\set file_ord    :csv_olist '/olist_orders_dataset.csv'
\set file_items  :csv_olist '/olist_order_items_dataset.csv'
\set file_rev    :csv_olist '/olist_order_reviews_dataset.csv'
\set file_pay    :csv_olist '/olist_order_payments_dataset.csv'

\set file_veh    :csv_fleet '/fleet_vehicles.csv'
\set file_drv    :csv_fleet '/fleet_drivers.csv'
\set file_del    :csv_fleet '/fleet_deliveries.csv'
\set file_mnt    :csv_fleet '/fleet_maintenance.csv'
\set file_inc    :csv_fleet '/fleet_incidents.csv'

-- ─────────────────────────────────────────
-- OLIST — orden respeta dependencias de FK
-- ─────────────────────────────────────────

-- 1. geolocation (sin FK — cargar primero)
COPY olist_geolocation (
    geolocation_zip_code_prefix,
    geolocation_lat,
    geolocation_lng,
    geolocation_city,
    geolocation_state
)
FROM :'file_geo'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- 2. customers
COPY olist_customers (
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state
)
FROM :'file_cust'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- 3. sellers
COPY olist_sellers (
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state
)
FROM :'file_sell'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- 4. products
COPY olist_products (
    product_id,
    product_category_name,
    product_name_lenght,
    product_description_lenght,
    product_photos_qty,
    product_weight_g,
    product_length_cm,
    product_height_cm,
    product_width_cm
)
FROM :'file_prod'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- 5. category translations
COPY product_category_name_translation (
    product_category_name,
    product_category_name_english
)
FROM :'file_trans'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- 6. orders
COPY olist_orders (
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    order_approved_at,
    order_delivered_carrier_date,
    order_delivered_customer_date,
    order_estimated_delivery_date
)
FROM :'file_ord'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- 7. order_items
COPY olist_order_items (
    order_id,
    order_item_id,
    product_id,
    seller_id,
    shipping_limit_date,
    price,
    freight_value
)
FROM :'file_items'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- 8. order_reviews
COPY olist_order_reviews (
    review_id,
    order_id,
    review_score,
    review_comment_title,
    review_comment_message,
    review_creation_date,
    review_answer_timestamp
)
FROM :'file_rev'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '', QUOTE '"');
-- QUOTE '"' necesario: review_comment_message puede contener comas y saltos de linea

-- 9. order_payments
COPY olist_order_payments (
    order_id,
    payment_sequential,
    payment_type,
    payment_installments,
    payment_value
)
FROM :'file_pay'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- ─────────────────────────────────────────
-- FLOTA SINTETICA
-- ─────────────────────────────────────────

-- 10. fleet_vehicles
COPY fleet_vehicles (
    vehicle_id,
    plate,
    type,
    brand,
    model,
    year,
    capacity_kg,
    fuel_type,
    fuel_consumption_rate_lh,
    status
)
FROM :'file_veh'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- Resetear secuencia SERIAL al maximo ya cargado
SELECT setval('fleet_vehicles_vehicle_id_seq', MAX(vehicle_id)) FROM fleet_vehicles;

-- 11. fleet_drivers
COPY fleet_drivers (
    driver_id,
    name,
    license_type,
    hire_date,
    region_assigned,
    vehicle_id,
    driver_behavior_score,
    fatigue_score_avg
)
FROM :'file_drv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

SELECT setval('fleet_drivers_driver_id_seq', MAX(driver_id)) FROM fleet_drivers;

-- 12. fleet_deliveries
COPY fleet_deliveries (
    delivery_id,
    order_id,
    vehicle_id,
    driver_id,
    pickup_date,
    carrier_pickup_date,
    delivery_date,
    distance_km,
    route_state,
    delivery_status,
    eta_variation_hours,
    loading_unloading_time_h,
    route_risk_level,
    traffic_congestion_level,
    weather_condition_severity
)
FROM :'file_del'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

SELECT setval('fleet_deliveries_delivery_id_seq', MAX(delivery_id)) FROM fleet_deliveries;

-- 13. fleet_maintenance
COPY fleet_maintenance (
    maintenance_id,
    vehicle_id,
    date,
    type,
    component,
    cost_brl,
    downtime_hours,
    mileage_at_service
)
FROM :'file_mnt'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

SELECT setval('fleet_maintenance_maintenance_id_seq', MAX(maintenance_id)) FROM fleet_maintenance;

-- 14. fleet_incidents
COPY fleet_incidents (
    incident_id,
    vehicle_id,
    date,
    type,
    disruption_likelihood,
    impact_on_delivery_h,
    order_id
)
FROM :'file_inc'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

SELECT setval('fleet_incidents_incident_id_seq', MAX(incident_id)) FROM fleet_incidents;

-- =============================================================
-- DATA AUDIT — verificacion post-import
-- =============================================================
-- Actualizar estadisticas antes de consultar pg_stat
ANALYZE;

-- -------------------------------------------------------------
-- 1. VOLUMENES EXACTOS POR TABLA
-- (COUNT(*) real, no estimacion de pg_stat_user_tables)
-- -------------------------------------------------------------
SELECT tabla, filas_reales, filas_esperadas,
    CASE WHEN filas_reales = filas_esperadas THEN 'OK'
         WHEN filas_reales > 0              THEN 'REVISAR'
         ELSE                                    'ERROR: tabla vacia'
    END AS resultado
FROM (
    VALUES
    ('olist_geolocation',                (SELECT COUNT(*) FROM olist_geolocation),                1000163),
    ('olist_customers',                  (SELECT COUNT(*) FROM olist_customers),                     99441),
    ('olist_sellers',                    (SELECT COUNT(*) FROM olist_sellers),                        3095),
    ('olist_products',                   (SELECT COUNT(*) FROM olist_products),                      32952),
    ('product_category_name_translation',(SELECT COUNT(*) FROM product_category_name_translation),     71),
    ('olist_orders',                     (SELECT COUNT(*) FROM olist_orders),                        99441),
    ('olist_order_items',                (SELECT COUNT(*) FROM olist_order_items),                  112650),
    ('olist_order_reviews',              (SELECT COUNT(*) FROM olist_order_reviews),                 99224),
    ('olist_order_payments',             (SELECT COUNT(*) FROM olist_order_payments),               103886),
    ('fleet_vehicles',                   (SELECT COUNT(*) FROM fleet_vehicles),                         60),
    ('fleet_drivers',                    (SELECT COUNT(*) FROM fleet_drivers),                          40),
    ('fleet_deliveries',                 (SELECT COUNT(*) FROM fleet_deliveries),                    96470),
    ('fleet_maintenance',                (SELECT COUNT(*) FROM fleet_maintenance),                     698),
    ('fleet_incidents',                  (SELECT COUNT(*) FROM fleet_incidents),                       3612)
) AS t(tabla, filas_reales, filas_esperadas)
ORDER BY tabla;

-- -------------------------------------------------------------
-- 2. SECUENCIAS SERIAL — verificar sincronizacion post-COPY
-- -------------------------------------------------------------
-- Un setval() incorrecto generaria conflicto de PK en el primer
-- INSERT posterior al import.
SELECT
    seq.sequencename                AS secuencia,
    seq.last_value                  AS ultimo_valor,
    maximos.max_id                  AS max_id_en_tabla,
    CASE WHEN seq.last_value = maximos.max_id
         THEN 'OK' ELSE 'ERROR: secuencia desincronizada' END AS resultado
FROM pg_sequences seq
JOIN (
    VALUES
    ('fleet_vehicles_vehicle_id_seq',  (SELECT MAX(vehicle_id)    FROM fleet_vehicles)),
    ('fleet_drivers_driver_id_seq',    (SELECT MAX(driver_id)     FROM fleet_drivers)),
    ('fleet_deliveries_delivery_id_seq',(SELECT MAX(delivery_id)  FROM fleet_deliveries)),
    ('fleet_maintenance_maintenance_id_seq',(SELECT MAX(maintenance_id) FROM fleet_maintenance)),
    ('fleet_incidents_incident_id_seq',(SELECT MAX(incident_id)   FROM fleet_incidents))
) AS maximos(nombre, max_id)
  ON seq.sequencename = maximos.nombre
WHERE seq.schemaname = 'public'
ORDER BY seq.sequencename;

-- -------------------------------------------------------------
-- 3. INTEGRIDAD REFERENCIAL CRITICA
-- -------------------------------------------------------------
-- 3a. Ordenes delivered sin entrega en flota
--     Resultado esperado: 8 (ordenes con delivery_date=NULL en Olist)
SELECT
    COUNT(*)                        AS ordenes_delivered_sin_flota,
    8                               AS esperado_documentado,
    CASE WHEN COUNT(*) = 8
         THEN 'OK (bug conocido de Olist)'
         WHEN COUNT(*) = 0
         THEN 'OK (cero diferencias)'
         ELSE 'REVISAR: valor inesperado' END AS resultado
FROM olist_orders o
LEFT JOIN fleet_deliveries fd ON fd.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND fd.order_id IS NULL;

-- 3b. Items de flota sin orden en Olist (debe ser 0)
SELECT
    COUNT(*)                        AS entregas_sin_orden_olist,
    0                               AS esperado,
    CASE WHEN COUNT(*) = 0
         THEN 'OK' ELSE 'ERROR: FK rota' END AS resultado
FROM fleet_deliveries fd
LEFT JOIN olist_orders o ON o.order_id = fd.order_id
WHERE o.order_id IS NULL;

-- -------------------------------------------------------------
-- 4. RANGOS DE COLUMNAS NUEVAS EN FLEET_DELIVERIES
-- -------------------------------------------------------------
SELECT
    'traffic_congestion_level'      AS columna,
    ROUND(MIN(traffic_congestion_level)::NUMERIC, 2)  AS minimo,
    ROUND(AVG(traffic_congestion_level)::NUMERIC, 2)  AS promedio,
    ROUND(MAX(traffic_congestion_level)::NUMERIC, 2)  AS maximo,
    COUNT(*) FILTER (WHERE traffic_congestion_level NOT BETWEEN 0 AND 10) AS fuera_rango,
    CASE WHEN COUNT(*) FILTER (WHERE traffic_congestion_level NOT BETWEEN 0 AND 10) = 0
         THEN 'OK' ELSE 'ERROR: valores fuera del rango 0-10' END AS resultado
FROM fleet_deliveries
UNION ALL
SELECT
    'weather_condition_severity',
    ROUND(MIN(weather_condition_severity)::NUMERIC, 3),
    ROUND(AVG(weather_condition_severity)::NUMERIC, 3),
    ROUND(MAX(weather_condition_severity)::NUMERIC, 3),
    COUNT(*) FILTER (WHERE weather_condition_severity NOT BETWEEN 0 AND 1),
    CASE WHEN COUNT(*) FILTER (WHERE weather_condition_severity NOT BETWEEN 0 AND 1) = 0
         THEN 'OK' ELSE 'ERROR: valores fuera del rango 0-1' END
FROM fleet_deliveries;

-- -------------------------------------------------------------
-- 5. DISTRIBUCION DE VEHICULOS Y DELIVERY STATUS
-- -------------------------------------------------------------
SELECT type AS tipo_vehiculo, COUNT(*) AS cantidad FROM fleet_vehicles
GROUP BY type ORDER BY type;
-- Esperado: moto=25, van=25, truck=10

SELECT
    delivery_status,
    COUNT(*)                                            AS entregas,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1)  AS pct
FROM fleet_deliveries
GROUP BY delivery_status;
-- Esperado: on_time ~75%, delayed ~25%

-- -------------------------------------------------------------
-- 6. RESUMEN EJECUTIVO — una fila por verificacion clave
-- -------------------------------------------------------------
SELECT verificacion, esperado, resultado FROM (
    VALUES
    ('olist_orders cargadas', '99441',
     (SELECT CASE WHEN COUNT(*) = 99441 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT END FROM olist_orders)),
    ('fleet_deliveries cargadas', '96470',
     (SELECT CASE WHEN COUNT(*) = 96470 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT END FROM fleet_deliveries)),
    ('olist_order_items cargadas', '112650',
     (SELECT CASE WHEN COUNT(*) = 112650 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT END FROM olist_order_items)),
    ('olist_order_reviews cargadas', '99224',
     (SELECT CASE WHEN COUNT(*) = 99224 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT END FROM olist_order_reviews)),
    ('fleet_maintenance cargada', '698',
     (SELECT CASE WHEN COUNT(*) = 698 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT END FROM fleet_maintenance)),
    ('fleet_incidents cargados', '3612',
     (SELECT CASE WHEN COUNT(*) = 3612 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT END FROM fleet_incidents)),
    ('FK deliveries->orders intacta', '0 huerfanos',
     (SELECT CASE WHEN COUNT(*) = 0 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT || ' huerfanos' END
      FROM fleet_deliveries fd
      LEFT JOIN olist_orders o ON o.order_id = fd.order_id WHERE o.order_id IS NULL)),
    ('traffic_fuera_rango_0_10', '0',
     (SELECT CASE WHEN COUNT(*) = 0 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT END
      FROM fleet_deliveries WHERE traffic_congestion_level NOT BETWEEN 0 AND 10)),
    ('weather_fuera_rango_0_1', '0',
     (SELECT CASE WHEN COUNT(*) = 0 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT END
      FROM fleet_deliveries WHERE weather_condition_severity NOT BETWEEN 0 AND 1)),
    ('secuencia_fleet_deliveries', 'max=96470',
     (SELECT CASE WHEN last_value = (SELECT MAX(delivery_id) FROM fleet_deliveries)
                  THEN 'OK' ELSE 'ERROR: last_value=' || last_value::TEXT END
      FROM pg_sequences WHERE sequencename='fleet_deliveries_delivery_id_seq'))
) AS t(verificacion, esperado, resultado)
ORDER BY
    CASE WHEN resultado LIKE 'ERROR%' THEN 0 ELSE 1 END,  -- errores primero
    verificacion;
