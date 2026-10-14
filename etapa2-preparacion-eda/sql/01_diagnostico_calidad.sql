-- =====================================================================
-- ETAPA 2 · 01_diagnostico_calidad.sql
-- Diagnóstico de calidad de datos sobre olist_logistics_db (solo lectura)
-- Ejecutar: psql -U postgres -d olist_logistics_db -f 01_diagnostico_calidad.sql > ../docs/diagnostico_calidad.txt
-- Resultado: una tabla única (dimension | chequeo | afectados | total | pct | accion)
--            que alimenta docs/informe_calidad_datos.md
-- =====================================================================
\pset format aligned
\timing on

WITH
-- ---------- 1. NULOS ------------------------------------------------
nulos AS (
  SELECT 'nulos' AS dimension, 'orders delivered sin order_delivered_customer_date' AS chequeo,
         COUNT(*) FILTER (WHERE order_status='delivered' AND order_delivered_customer_date IS NULL) AS afectados,
         COUNT(*) FILTER (WHERE order_status='delivered') AS total,
         'Excluir del dataset analítico' AS accion
  FROM olist_orders
  UNION ALL
  SELECT 'nulos','orders delivered sin order_delivered_carrier_date',
         COUNT(*) FILTER (WHERE order_status='delivered' AND order_delivered_carrier_date IS NULL),
         COUNT(*) FILTER (WHERE order_status='delivered'), 'Excluir (no se puede calcular tiempo de despacho)'
  FROM olist_orders
  UNION ALL
  SELECT 'nulos','products sin categoría',
         COUNT(*) FILTER (WHERE product_category_name IS NULL), COUNT(*),
         'Imputar categoría = ''sin_categoria'''
  FROM olist_products
  UNION ALL
  SELECT 'nulos','products sin product_weight_g',
         COUNT(*) FILTER (WHERE product_weight_g IS NULL), COUNT(*),
         'Imputar con mediana de la categoría'
  FROM olist_products
  UNION ALL
  SELECT 'nulos','reviews sin comentario (message)',
         COUNT(*) FILTER (WHERE review_comment_message IS NULL), COUNT(*),
         'Normal: dato opcional. No imputar'
  FROM olist_order_reviews
),
-- ---------- 2. DUPLICADOS -------------------------------------------
duplicados AS (
  SELECT 'duplicados','review_id repetido (filas sobrantes)',
         COUNT(*) - COUNT(DISTINCT review_id), COUNT(*),
         'Usar review_pk; en el dataset se toma la última reseña por orden'
  FROM olist_order_reviews
  UNION ALL
  SELECT 'duplicados','órdenes con más de 1 reseña',
         COUNT(*) FILTER (WHERE n > 1), COUNT(*),
         'Agregar a 1 reseña por orden (la más reciente) para no duplicar filas'
  FROM (SELECT order_id, COUNT(*) n FROM olist_order_reviews GROUP BY order_id) x
  UNION ALL
  SELECT 'duplicados','órdenes con más de 1 ítem (riesgo de fan-out en JOIN)',
         COUNT(*) FILTER (WHERE n > 1), COUNT(*),
         'Agregar ítems a nivel orden (grano del dataset = 1 fila por orden)'
  FROM (SELECT order_id, COUNT(*) n FROM olist_order_items GROUP BY order_id) x
  UNION ALL
  SELECT 'duplicados','órdenes con más de 1 vendedor',
         COUNT(*) FILTER (WHERE n > 1), COUNT(*),
         'Tomar el vendedor del ítem 1 como origen del envío'
  FROM (SELECT order_id, COUNT(DISTINCT seller_id) n FROM olist_order_items GROUP BY order_id) x
  UNION ALL
  SELECT 'duplicados','órdenes con más de 1 pago',
         COUNT(*) FILTER (WHERE n > 1), COUNT(*),
         'Sumar payment_value; payment_type = método del pago 1'
  FROM (SELECT order_id, COUNT(*) n FROM olist_order_payments GROUP BY order_id) x
  UNION ALL
  SELECT 'duplicados','clientes recurrentes (customer_unique_id con >1 customer_id)',
         COUNT(*) FILTER (WHERE n > 1), COUNT(*),
         'No es error: customer_id cambia por orden. Usar customer_unique_id para recurrencia'
  FROM (SELECT customer_unique_id, COUNT(*) n FROM olist_customers GROUP BY customer_unique_id) x
  UNION ALL
  SELECT 'duplicados','zip prefixes con múltiples coordenadas en geolocation',
         COUNT(*) FILTER (WHERE n > 1), COUNT(*),
         'Colapsar a 1 centroide por zip (mv_geo_zip)'
  FROM (SELECT geolocation_zip_code_prefix, COUNT(*) n FROM olist_geolocation GROUP BY 1) x
),
-- ---------- 3. INCONSISTENCIAS (lógica temporal y de negocio) --------
inconsistencias AS (
  SELECT 'inconsistencias','carrier_date > customer_date (despacho posterior a entrega)',
         COUNT(*) FILTER (WHERE order_delivered_carrier_date > order_delivered_customer_date),
         COUNT(*) FILTER (WHERE order_status='delivered'),
         'Excluir: secuencia temporal imposible'
  FROM olist_orders
  UNION ALL
  SELECT 'inconsistencias','purchase_ts > carrier_date',
         COUNT(*) FILTER (WHERE order_purchase_timestamp > order_delivered_carrier_date),
         COUNT(*) FILTER (WHERE order_status='delivered'),
         'Excluir: secuencia temporal imposible'
  FROM olist_orders
  UNION ALL
  SELECT 'inconsistencias','approved_at < purchase_ts',
         COUNT(*) FILTER (WHERE order_approved_at < order_purchase_timestamp),
         COUNT(*), 'Flaguear'
  FROM olist_orders
  UNION ALL
  SELECT 'inconsistencias','estimated_delivery < purchase_ts',
         COUNT(*) FILTER (WHERE order_estimated_delivery_date < order_purchase_timestamp),
         COUNT(*), 'Excluir'
  FROM olist_orders
  UNION ALL
  SELECT 'inconsistencias','fleet_deliveries: delivery_date <> olist.order_delivered_customer_date',
         COUNT(*) FILTER (WHERE fd.delivery_date IS DISTINCT FROM o.order_delivered_customer_date),
         COUNT(*), 'Debe ser 0 (la fuente sintética hereda las fechas de Olist)'
  FROM fleet_deliveries fd JOIN olist_orders o USING (order_id)
  UNION ALL
  SELECT 'inconsistencias','delivery_status (flota sintética) vs. demora real Olist: desacuerdo',
         COUNT(*) FILTER (WHERE (fd.delivery_status='delayed')
                                <> (o.order_delivered_customer_date > o.order_estimated_delivery_date)),
         COUNT(*) FILTER (WHERE o.order_delivered_customer_date IS NOT NULL),
         'Debe ser 0 (delivery_status se deriva de la demora real de Olist)'
  FROM fleet_deliveries fd JOIN olist_orders o USING (order_id)
  UNION ALL
  SELECT 'inconsistencias','items con price = 0',
         COUNT(*) FILTER (WHERE price = 0), COUNT(*),
         'Flaguear y revisar (la vista NO los excluye)'
  FROM olist_order_items
  UNION ALL
  SELECT 'inconsistencias','items con freight_value = 0',
         COUNT(*) FILTER (WHERE freight_value = 0), COUNT(*),
         'Conservar: posible envío gratis'
  FROM olist_order_items
  UNION ALL
  SELECT 'inconsistencias','payments con payment_value = 0',
         COUNT(*) FILTER (WHERE payment_value = 0), COUNT(*), 'Flaguear'
  FROM olist_order_payments
  UNION ALL
  SELECT 'inconsistencias','vehículo asignado inconsistente con peso (regla moto/van/truck)',
         COUNT(*) FILTER (WHERE v.type <>
              CASE WHEN p.product_weight_g < 300 THEN 'moto'
                   WHEN p.product_weight_g < 2000 THEN 'van' ELSE 'truck' END),
         COUNT(*), 'Debe ser 0 (la regla moto/van/truck usa el peso del primer ítem)'
  FROM fleet_deliveries fd
  JOIN fleet_vehicles v USING (vehicle_id)
  JOIN olist_order_items i ON i.order_id = fd.order_id AND i.order_item_id = 1
  JOIN olist_products p ON p.product_id = i.product_id
  WHERE p.product_weight_g > 0
  UNION ALL
  SELECT 'inconsistencias','conductor de la entrega con vehículo distinto al de la entrega',
         COUNT(*) FILTER (WHERE d.vehicle_id <> fd.vehicle_id), COUNT(*),
         'Debe ser 0 (1 conductor = 1 vehículo)'
  FROM fleet_deliveries fd JOIN fleet_drivers d USING (driver_id)
  UNION ALL
  SELECT 'inconsistencias','entregas donde la licencia del conductor no habilita el tipo de vehículo (A=moto, B=van, E=truck)',
         COUNT(*) FILTER (WHERE d.license_type <>
              CASE v.type WHEN 'moto' THEN 'A' WHEN 'van' THEN 'B' ELSE 'E' END),
         COUNT(*), 'Debe ser 0 (la licencia es coherente con el vehículo)'
  FROM fleet_deliveries fd
  JOIN fleet_drivers d  USING (driver_id)
  JOIN fleet_vehicles v ON v.vehicle_id = fd.vehicle_id
),
-- ---------- 4. FORMATOS Y CATEGÓRICAS -------------------------------
categoricas AS (
  SELECT 'categóricas','order_status fuera de catálogo',
         COUNT(*) FILTER (WHERE order_status NOT IN
           ('delivered','shipped','canceled','unavailable','processing','created','approved','invoiced')),
         COUNT(*), 'Debe ser 0'
  FROM olist_orders
  UNION ALL
  SELECT 'categóricas','customer_state fuera de las 27 siglas IBGE',
         COUNT(*) FILTER (WHERE customer_state NOT IN
           ('AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO')),
         COUNT(*), 'Debe ser 0'
  FROM olist_customers
  UNION ALL
  SELECT 'categóricas','payment_type = not_defined',
         COUNT(*) FILTER (WHERE payment_type='not_defined'), COUNT(*), 'Agrupar en "otro"'
  FROM olist_order_payments
  UNION ALL
  SELECT 'categóricas','categorías de producto sin traducción al inglés',
         COUNT(*) FILTER (WHERE t.product_category_name IS NULL), COUNT(*),
         'COALESCE a nombre en portugués (listar con la consulta de detalle al final del script)'
  FROM (SELECT DISTINCT product_category_name FROM olist_products WHERE product_category_name IS NOT NULL) c
  LEFT JOIN product_category_name_translation t USING (product_category_name)
  UNION ALL
  SELECT 'categóricas','zip prefix con longitud <> 5 (pérdida de ceros a la izquierda)',
         COUNT(*) FILTER (WHERE LENGTH(customer_zip_code_prefix) <> 5), COUNT(*), 'Debe ser 0 (CHAR(5))'
  FROM olist_customers
),
-- ---------- 5. VALORES EXTREMOS -------------------------------------
extremos AS (
  SELECT 'outliers','product_weight_g = 0',
         COUNT(*) FILTER (WHERE product_weight_g = 0), COUNT(*),
         'Imputar con mediana de la categoría'
  FROM olist_products
  UNION ALL
  SELECT 'outliers','product_weight_g > Q3+3·IQR (extremo severo)',
         COUNT(*) FILTER (WHERE product_weight_g > q.q3 + 3*(q.q3-q.q1)), COUNT(*),
         'Conservar (son pesos reales); ver winsorización solo para modelos'
  FROM olist_products,
       LATERAL (SELECT percentile_cont(.25) WITHIN GROUP (ORDER BY product_weight_g) q1,
                       percentile_cont(.75) WITHIN GROUP (ORDER BY product_weight_g) q3
                FROM olist_products WHERE product_weight_g > 0) q
  UNION ALL
  SELECT 'outliers','freight_value > Q3+3·IQR',
         COUNT(*) FILTER (WHERE freight_value > q.q3 + 3*(q.q3-q.q1)), COUNT(*),
         'Conservar y flaguear (flete real alto en regiones remotas)'
  FROM olist_order_items,
       LATERAL (SELECT percentile_cont(.25) WITHIN GROUP (ORDER BY freight_value) q1,
                       percentile_cont(.75) WITHIN GROUP (ORDER BY freight_value) q3
                FROM olist_order_items) q
  UNION ALL
  SELECT 'outliers','tiempo de entrega > 60 días',
         COUNT(*) FILTER (WHERE order_delivered_customer_date - order_purchase_timestamp > INTERVAL '60 days'),
         COUNT(*) FILTER (WHERE order_delivered_customer_date IS NOT NULL),
         'Conservar y flaguear (entregas reales muy tardías)'
  FROM olist_orders
  UNION ALL
  SELECT 'outliers','coordenadas fuera del bounding box de Brasil',
         COUNT(*) FILTER (WHERE geolocation_lat NOT BETWEEN -34.0 AND 5.27
                             OR geolocation_lng NOT BETWEEN -73.99 AND -34.79),
         COUNT(*), 'Filtrar al construir mv_geo_zip'
  FROM olist_geolocation
  UNION ALL
  SELECT 'outliers','fleet: distance_km censurado en los límites (=5 ó =6000)',
         COUNT(*) FILTER (WHERE distance_km IN (5, 6000)), COUNT(*),
         'Informativo: entregas intra-zona (haversine x factor de ruta < 5 km) quedan en el piso del rango declarado'
  FROM fleet_deliveries
  UNION ALL
  SELECT 'outliers','fleet: eta_variation_hours censurado en los límites (=-168 ó =336)',
         COUNT(*) FILTER (WHERE eta_variation_hours IN (-168, 336)), COUNT(*),
         'Informativo: la variable está acotada por el generador; este porcentaje es la censura'
  FROM fleet_deliveries
  UNION ALL
  SELECT 'outliers','fleet: eta_variation_hours fuera de [-168, 336]',
         COUNT(*) FILTER (WHERE eta_variation_hours NOT BETWEEN -168 AND 336), COUNT(*), 'Debe ser 0 (rango declarado)'
  FROM fleet_deliveries
  UNION ALL
  SELECT 'outliers','fleet: distance_km fuera de [5, 6000]',
         COUNT(*) FILTER (WHERE distance_km NOT BETWEEN 5 AND 6000), COUNT(*), 'Debe ser 0 (rango declarado; CHECK chk_del_dist)'
  FROM fleet_deliveries
),
-- ---------- 6. INTEGRIDAD REFERENCIAL -------------------------------
integridad AS (
  SELECT 'integridad','órdenes delivered sin registro en fleet_deliveries',
         COUNT(*), (SELECT COUNT(*) FROM olist_orders WHERE order_status='delivered'),
         'Excluir (INNER JOIN en el dataset analítico)'
  FROM olist_orders o
  WHERE o.order_status='delivered'
    AND NOT EXISTS (SELECT 1 FROM fleet_deliveries f WHERE f.order_id = o.order_id)
  UNION ALL
  SELECT 'integridad','fleet_deliveries cuya orden NO está delivered',
         COUNT(*), (SELECT COUNT(*) FROM fleet_deliveries), 'Debe ser 0'
  FROM fleet_deliveries f JOIN olist_orders o USING (order_id)
  WHERE o.order_status <> 'delivered'
  UNION ALL
  SELECT 'integridad','órdenes sin ítems',
         COUNT(*), (SELECT COUNT(*) FROM olist_orders), 'Excluir del dataset (sin peso/flete)'
  FROM olist_orders o WHERE NOT EXISTS (SELECT 1 FROM olist_order_items i WHERE i.order_id=o.order_id)
  UNION ALL
  SELECT 'integridad','órdenes delivered sin reseña',
         COUNT(*), (SELECT COUNT(*) FROM olist_orders WHERE order_status='delivered'),
         'Conservar con review_score NULL (LEFT JOIN); excluir solo de KPIs de satisfacción'
  FROM olist_orders o
  WHERE o.order_status='delivered'
    AND NOT EXISTS (SELECT 1 FROM olist_order_reviews r WHERE r.order_id=o.order_id)
  UNION ALL
  SELECT 'integridad','ítems apuntando al placeholder unknown_product_placeholder',
         COUNT(*), (SELECT COUNT(*) FROM olist_order_items), 'Excluir peso del cálculo (peso desconocido)'
  FROM olist_order_items WHERE product_id='unknown_product_placeholder'
  UNION ALL
  SELECT 'integridad','clientes con zip sin coordenadas en geolocation',
         (SELECT COUNT(*) FROM olist_customers c WHERE NOT EXISTS
            (SELECT 1 FROM olist_geolocation g WHERE g.geolocation_zip_code_prefix=c.customer_zip_code_prefix)),
         (SELECT COUNT(*) FROM olist_customers), 'distancia_haversine_km = NULL; distance_km sí existe (usa el centroide del estado como respaldo)'
  UNION ALL
  SELECT 'integridad','conductores cuyo vehículo está en baja',
         COUNT(*), (SELECT COUNT(*) FROM fleet_drivers), 'Debe ser 0 (conductores solo en vehículos activos)'
  FROM fleet_drivers d JOIN fleet_vehicles v USING (vehicle_id) WHERE v.status='baja'
  UNION ALL
  SELECT 'integridad','vehículos con más de 1 conductor (rompe la relación 1:1)',
         COUNT(*), (SELECT COUNT(DISTINCT vehicle_id) FROM fleet_drivers), 'Debe ser 0 (1 conductor por vehículo activo)'
  FROM (SELECT vehicle_id FROM fleet_drivers GROUP BY vehicle_id HAVING COUNT(*) > 1) x
  UNION ALL
  SELECT 'integridad','entregas realizadas con vehículo en baja',
         COUNT(*), (SELECT COUNT(*) FROM fleet_deliveries), 'Debe ser 0 (las bajas no reciben entregas; status es una foto sin fecha)'
  FROM fleet_deliveries d JOIN fleet_vehicles v USING (vehicle_id) WHERE v.status='baja'
),
-- ---------- 7. FECHAS -----------------------------------------------
fechas AS (
  SELECT 'fechas','órdenes por fuera de 2016-09 … 2018-10 (rango Olist)',
         COUNT(*) FILTER (WHERE order_purchase_timestamp < '2016-09-01' OR order_purchase_timestamp >= '2018-11-01'),
         COUNT(*), 'Informativo'
  FROM olist_orders
  UNION ALL
  SELECT 'fechas','mantenimientos fuera de 2016-01 … 2018-12',
         COUNT(*) FILTER (WHERE date NOT BETWEEN '2016-01-01' AND '2018-12-31'), COUNT(*), 'Debe ser 0'
  FROM fleet_maintenance
  UNION ALL
  SELECT 'fechas','mantenimientos anteriores al año de fabricación del vehículo',
         COUNT(*) FILTER (WHERE EXTRACT(YEAR FROM m.date) < v.year), COUNT(*), 'Debe ser 0'
  FROM fleet_maintenance m JOIN fleet_vehicles v USING (vehicle_id)
  UNION ALL
  SELECT 'fechas','incidentes con fecha fuera del viaje (pickup–delivery)',
         COUNT(*) FILTER (WHERE i.date < fd.pickup_date::date OR i.date > fd.delivery_date::date),
         COUNT(*), 'Informativo'
  FROM fleet_incidents i JOIN fleet_deliveries fd USING (order_id)
  UNION ALL
  SELECT 'fechas','conductores con hire_date posterior a su primera entrega',
         COUNT(*), (SELECT COUNT(*) FROM fleet_drivers), 'Debe ser 0'
  FROM fleet_drivers d
  WHERE d.hire_date > (SELECT MIN(pickup_date) FROM fleet_deliveries f WHERE f.driver_id=d.driver_id)
)
SELECT dimension, chequeo, afectados, total,
       ROUND(100.0 * afectados / NULLIF(total,0), 3) AS pct, accion
FROM (SELECT * FROM nulos UNION ALL SELECT * FROM duplicados UNION ALL SELECT * FROM inconsistencias
      UNION ALL SELECT * FROM categoricas UNION ALL SELECT * FROM extremos
      UNION ALL SELECT * FROM integridad UNION ALL SELECT * FROM fechas) t
ORDER BY dimension, afectados DESC;

-- ---------- DETALLE: categorías sin traducción (para completar el informe) ----------
SELECT DISTINCT p.product_category_name AS categoria_sin_traduccion
FROM olist_products p
LEFT JOIN product_category_name_translation t USING (product_category_name)
WHERE p.product_category_name IS NOT NULL AND t.product_category_name IS NULL
ORDER BY 1;
