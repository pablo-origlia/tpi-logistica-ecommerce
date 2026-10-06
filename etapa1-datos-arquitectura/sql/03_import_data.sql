-- =============================================================
-- 03_import_data.sql
-- Carga de datos: COPY desde CSV hacia las tablas de la BD
-- Base de datos: olist_logistics_db (PostgreSQL 15+)
-- Proyecto TPI — Análisis de Datos Masivos, UCASAL 2026
-- =============================================================
-- ANTES DE EJECUTAR:
--   1. Ajustar la variable :csv_path al directorio donde están
--      los CSV (ver instrucciones abajo).
--   2. Ejecutar como superusuario o con permisos pg_read_server_files.
--   3. Los archivos deben estar accesibles desde el servidor PostgreSQL.
--
-- AJUSTE DE RUTA:
--   Opción A — psql con variable:
--     psql -v csv_olist="C:/ruta/etapa1-datos-arquitectura/raw" \
--          -v csv_fleet="C:/ruta/etapa1-datos-arquitectura/fleet_synthetic" \
--          -d olist_logistics_db -f 03_import_data.sql
--
--   Opción B — reemplazar :'csv_olist' y :'csv_fleet' con la ruta real.
--
-- NOTA: En Windows usar barras / no \ en las rutas dentro de COPY.
-- =============================================================

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
FROM :'csv_olist' || '/olist_geolocation_dataset.csv'
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
FROM :'csv_olist' || '/olist_customers_dataset.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- 3. sellers
COPY olist_sellers (
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state
)
FROM :'csv_olist' || '/olist_sellers_dataset.csv'
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
FROM :'csv_olist' || '/olist_products_dataset.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- 5. category translations
COPY product_category_name_translation (
    product_category_name,
    product_category_name_english
)
FROM :'csv_olist' || '/product_category_name_translation.csv'
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
FROM :'csv_olist' || '/olist_orders_dataset.csv'
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
FROM :'csv_olist' || '/olist_order_items_dataset.csv'
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
FROM :'csv_olist' || '/olist_order_reviews_dataset.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '', QUOTE '"');
-- QUOTE '"' necesario: review_comment_message puede contener comas y saltos de línea

-- 9. order_payments
COPY olist_order_payments (
    order_id,
    payment_sequential,
    payment_type,
    payment_installments,
    payment_value
)
FROM :'csv_olist' || '/olist_order_payments_dataset.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- ─────────────────────────────────────────
-- FLOTA SINTÉTICA
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
FROM :'csv_fleet' || '/fleet_vehicles.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

-- Resetear secuencia SERIAL al máximo ya cargado
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
FROM :'csv_fleet' || '/fleet_drivers.csv'
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
    route_risk_level
)
FROM :'csv_fleet' || '/fleet_deliveries.csv'
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
FROM :'csv_fleet' || '/fleet_maintenance.csv'
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
FROM :'csv_fleet' || '/fleet_incidents.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8',
      NULL '');

SELECT setval('fleet_incidents_incident_id_seq', MAX(incident_id)) FROM fleet_incidents;

-- =============================================================
-- VERIFICACIÓN FINAL — ejecutar siempre después del import
-- =============================================================
SELECT
    relname                          AS tabla,
    n_live_tup                       AS filas_estimadas
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY relname;

-- Control de FK crítica: todas las órdenes 'delivered' tienen entrega registrada
SELECT
    COUNT(*)                         AS ordenes_delivered_sin_entrega_en_flota
FROM olist_orders o
LEFT JOIN fleet_deliveries fd ON fd.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND fd.order_id IS NULL;
-- Resultado esperado: 0

-- Distribución de tipos de vehículo
SELECT type, COUNT(*) FROM fleet_vehicles GROUP BY type ORDER BY type;
-- Esperado: moto=25, van=25, truck=10

-- Distribución de delivery_status
SELECT delivery_status, COUNT(*), ROUND(COUNT(*)*100.0/SUM(COUNT(*)) OVER(),1) AS pct
FROM fleet_deliveries GROUP BY delivery_status;
