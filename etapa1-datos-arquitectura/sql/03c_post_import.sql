SET client_encoding = 'UTF8';
-- =============================================================
-- 03c_post_import.sql
-- Validacion y limpieza minima post-import
-- Base de datos: olist_logistics_db (PostgreSQL 15+)
-- Proyecto TPI - Analisis de Datos Masivos, UCASAL 2026
-- =============================================================
-- CUANDO EJECUTAR: despues de 03_import_data.sql
-- PROPOSITO: diagnosticar la calidad real de los datos ingresados
--   y dejar registros de los problemas encontrados para Etapa 2.
--   NO modifica datos - solo reporta y documenta.
-- =============================================================


-- =============================================================
-- 1. DIAGNOSTICO: coordenadas fuera del bounding box de Brasil
-- =============================================================
-- Brasil: lat entre -34.0 y 5.27 | lng entre -73.99 y -34.79

SELECT
    'olist_geolocation'                     AS tabla,
    COUNT(*)                                AS total_filas,
    COUNT(*) FILTER (
        WHERE geolocation_lat NOT BETWEEN -34.0 AND 5.27
           OR geolocation_lng NOT BETWEEN -73.99 AND -34.79
    )                                       AS coords_fuera_brasil,
    ROUND(
        COUNT(*) FILTER (
            WHERE geolocation_lat NOT BETWEEN -34.0 AND 5.27
               OR geolocation_lng NOT BETWEEN -73.99 AND -34.79
        ) * 100.0 / COUNT(*), 2
    )                                       AS pct_invalidas
FROM olist_geolocation;

-- Distribucion de coordenadas invalidas por estado
-- (para saber si es un problema sistematico o aislado)
SELECT
    geolocation_state,
    COUNT(*) FILTER (
        WHERE geolocation_lat NOT BETWEEN -34.0 AND 5.27
           OR geolocation_lng NOT BETWEEN -73.99 AND -34.79
    )                                       AS coords_invalidas
FROM olist_geolocation
GROUP BY geolocation_state
HAVING COUNT(*) FILTER (
    WHERE geolocation_lat NOT BETWEEN -34.0 AND 5.27
       OR geolocation_lng NOT BETWEEN -73.99 AND -34.79
) > 0
ORDER BY coords_invalidas DESC;


-- =============================================================
-- 2. DIAGNOSTICO: productos con weight_g = 0 o NULL
-- =============================================================
SELECT
    'olist_products'                        AS tabla,
    COUNT(*)                                AS total_productos,
    COUNT(*) FILTER (WHERE product_weight_g = 0)    AS weight_cero,
    COUNT(*) FILTER (WHERE product_weight_g IS NULL) AS weight_nulo,
    COUNT(*) FILTER (WHERE product_weight_g > 0)     AS weight_valido
FROM olist_products;

-- Categorias con mayor cantidad de productos sin peso valido
SELECT
    product_category_name,
    COUNT(*) FILTER (WHERE product_weight_g = 0 OR product_weight_g IS NULL) AS sin_peso,
    COUNT(*)                                AS total_categoria
FROM olist_products
GROUP BY product_category_name
HAVING COUNT(*) FILTER (WHERE product_weight_g = 0 OR product_weight_g IS NULL) > 0
ORDER BY sin_peso DESC
LIMIT 10;


-- =============================================================
-- 3. DIAGNOSTICO: order_items con producto placeholder
-- =============================================================
SELECT
    'order_items con producto desconocido'  AS diagnostico,
    COUNT(*)                                AS registros_afectados,
    COUNT(DISTINCT order_id)               AS ordenes_afectadas
FROM olist_order_items
WHERE product_id = 'unknown_product_placeholder';


-- =============================================================
-- 4. DIAGNOSTICO: review_ids duplicados
-- =============================================================
SELECT
    'review_id duplicados'                  AS diagnostico,
    COUNT(*) - COUNT(DISTINCT review_id)   AS duplicados,
    COUNT(DISTINCT review_id)              AS review_ids_unicos,
    COUNT(*)                               AS total_resenas
FROM olist_order_reviews;

-- Ver algunos ejemplos de duplicados
SELECT
    review_id,
    COUNT(*)    AS apariciones,
    STRING_AGG(order_id, ' | ')    AS order_ids_asociados,
    STRING_AGG(review_score::TEXT, ' | ') AS scores
FROM olist_order_reviews
GROUP BY review_id
HAVING COUNT(*) > 1
ORDER BY apariciones DESC
LIMIT 5;


-- =============================================================
-- 5. DIAGNOSTICO: ordenes delivered sin entrega en flota
-- =============================================================
SELECT
    'ordenes delivered sin fleet_deliveries' AS diagnostico,
    COUNT(*)                                AS cantidad
FROM olist_orders o
LEFT JOIN fleet_deliveries fd ON fd.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND fd.order_id IS NULL;

-- Detalle de esas ordenes (para documentar en diccionario)
SELECT
    o.order_id,
    o.order_purchase_timestamp,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date
FROM olist_orders o
LEFT JOIN fleet_deliveries fd ON fd.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND fd.order_id IS NULL
ORDER BY o.order_purchase_timestamp;


-- =============================================================
-- 6. RESUMEN DE CALIDAD - tabla de referencia para Etapa 2
-- =============================================================
SELECT problema, detalle, accion_etapa2 FROM (
    VALUES
    ('coords_invalidas_geolocation',
     'Coordenadas fuera de Brasil en olist_geolocation (aprox. 0.03%)',
     'Filtrar en notebook limpieza: usar solo coords dentro del bounding box'),
    ('weight_cero_products',
     'Productos con product_weight_g = 0 - dato sucio del CSV original',
     'Imputar con mediana de la categoria o excluir del dataset analitico'),
    ('items_producto_desconocido',
     'order_items con producto no presente en catalogo - placeholder insertado',
     'Excluir del dataset analitico los items con product_id=unknown'),
    ('review_id_duplicados',
     'review_ids repetidos en el CSV - bug conocido del dataset Olist',
     'Agrupar por order_id para reviews; no usar review_id como join key'),
    ('delivered_sin_flota',
     '8 ordenes delivered sin registro en fleet_deliveries (0.008%)',
     'Excluir del dataset analitico - LEFT JOIN absorbe la diferencia')
) AS t(problema, detalle, accion_etapa2);
