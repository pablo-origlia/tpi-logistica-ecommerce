-- =============================================================
-- 01_ddl_olist.sql
-- DDL: Tablas de Olist Brazilian E-Commerce Dataset
-- Base de datos: olist_logistics_db (PostgreSQL 15+)
-- Proyecto TPI — Analisis de Datos Masivos, UCASAL 2026
-- =============================================================
-- Orden de creacion respeta dependencias de FK:
--   1. olist_geolocation          (sin FK entrante)
--   2. olist_customers            (usa zip → geolocation)
--   3. olist_sellers              (usa zip → geolocation)
--   4. olist_products             (sin FK)
--   5. product_category_name_translation
--   6. olist_orders               (FK → customers)
--   7. olist_order_items          (FK → orders, products, sellers)
--   8. olist_order_reviews        (FK → orders)
--   9. olist_order_payments       (FK → orders)
-- =============================================================

-- Evitar errores si se re-ejecuta (drop en orden inverso de FK)
DROP TABLE IF EXISTS olist_order_payments              CASCADE;
DROP TABLE IF EXISTS olist_order_reviews               CASCADE;
DROP TABLE IF EXISTS olist_order_items                 CASCADE;
DROP TABLE IF EXISTS olist_orders                      CASCADE;
DROP TABLE IF EXISTS product_category_name_translation CASCADE;
DROP TABLE IF EXISTS olist_products                    CASCADE;
DROP TABLE IF EXISTS olist_sellers                     CASCADE;
DROP TABLE IF EXISTS olist_customers                   CASCADE;
DROP TABLE IF EXISTS olist_geolocation                 CASCADE;

-- -------------------------------------------------------------
-- 1. olist_geolocation
--    ~1.000.163 filas — coordenadas por prefijo de CEP (ZIP)
--    Sin PK unica en el CSV original: el mismo zip puede tener
--    multiples coordenadas. Se usa como tabla de referencia.
-- -------------------------------------------------------------
CREATE TABLE olist_geolocation (
    geolocation_zip_code_prefix  CHAR(5)        NOT NULL,
    geolocation_lat              NUMERIC(10, 6) NOT NULL
        CONSTRAINT chk_geo_lat CHECK (geolocation_lat BETWEEN -34.0 AND 6.0),
    geolocation_lng              NUMERIC(10, 6) NOT NULL
        CONSTRAINT chk_geo_lng CHECK (geolocation_lng BETWEEN -74.0 AND -34.0),
    geolocation_city             VARCHAR(100),
    geolocation_state            CHAR(2)
        CONSTRAINT chk_geo_state CHECK (geolocation_state IN (
            'AC','AL','AM','AP','BA','CE','DF','ES','GO','MA',
            'MG','MS','MT','PA','PB','PE','PI','PR','RJ','RN',
            'RO','RR','RS','SC','SE','SP','TO'
        ))
);

-- Indice para los JOINs frecuentes por zip
CREATE INDEX idx_geo_zip ON olist_geolocation (geolocation_zip_code_prefix);
CREATE INDEX idx_geo_state ON olist_geolocation (geolocation_state);

COMMENT ON TABLE olist_geolocation IS
    'Coordenadas geograficas por prefijo de CEP brasileno. '
    'Una fila por coordenada medida — un zip puede tener varias filas. '
    'Fuente: Olist dataset, ~1M filas.';

-- -------------------------------------------------------------
-- 2. olist_customers
--    ~99.441 filas — un registro por cliente unico
-- -------------------------------------------------------------
CREATE TABLE olist_customers (
    customer_id              VARCHAR(40)  PRIMARY KEY,
    customer_unique_id       VARCHAR(40)  NOT NULL,
    customer_zip_code_prefix CHAR(5)      NOT NULL,
    customer_city            VARCHAR(100),
    customer_state           CHAR(2)      NOT NULL
        CONSTRAINT chk_cust_state CHECK (customer_state IN (
            'AC','AL','AM','AP','BA','CE','DF','ES','GO','MA',
            'MG','MS','MT','PA','PB','PE','PI','PR','RJ','RN',
            'RO','RR','RS','SC','SE','SP','TO'
        ))
);

CREATE INDEX idx_cust_zip   ON olist_customers (customer_zip_code_prefix);
CREATE INDEX idx_cust_state ON olist_customers (customer_state);
CREATE INDEX idx_cust_uid   ON olist_customers (customer_unique_id);

COMMENT ON TABLE olist_customers IS
    'Clientes de Olist. customer_id es el ID de orden (varia por pedido); '
    'customer_unique_id identifica al cliente real entre pedidos.';

-- -------------------------------------------------------------
-- 3. olist_sellers
--    ~3.095 filas — vendedores activos en la plataforma
-- -------------------------------------------------------------
CREATE TABLE olist_sellers (
    seller_id              VARCHAR(40)  PRIMARY KEY,
    seller_zip_code_prefix CHAR(5)      NOT NULL,
    seller_city            VARCHAR(100),
    seller_state           CHAR(2)      NOT NULL
        CONSTRAINT chk_sel_state CHECK (seller_state IN (
            'AC','AL','AM','AP','BA','CE','DF','ES','GO','MA',
            'MG','MS','MT','PA','PB','PE','PI','PR','RJ','RN',
            'RO','RR','RS','SC','SE','SP','TO'
        ))
);

CREATE INDEX idx_sel_zip   ON olist_sellers (seller_zip_code_prefix);
CREATE INDEX idx_sel_state ON olist_sellers (seller_state);

COMMENT ON TABLE olist_sellers IS
    'Vendedores registrados en Olist. seller_state determina la '
    'asignacion de conductor en fleet_drivers (vinculacion ficticia).';

-- -------------------------------------------------------------
-- 4. olist_products
--    ~32.951 filas — catalogo de productos
-- -------------------------------------------------------------
CREATE TABLE olist_products (
    product_id                 VARCHAR(40)  PRIMARY KEY,
    product_category_name      VARCHAR(100),
    product_name_lenght        SMALLINT     CONSTRAINT chk_prod_name_len  CHECK (product_name_lenght  > 0),
    product_description_lenght INTEGER      CONSTRAINT chk_prod_desc_len  CHECK (product_description_lenght > 0),
    product_photos_qty         SMALLINT     CONSTRAINT chk_prod_photos    CHECK (product_photos_qty >= 0),
    product_weight_g           INTEGER      CONSTRAINT chk_prod_weight    CHECK (product_weight_g > 0),
    product_length_cm          NUMERIC(6,1) CONSTRAINT chk_prod_length    CHECK (product_length_cm > 0),
    product_height_cm          NUMERIC(6,1) CONSTRAINT chk_prod_height    CHECK (product_height_cm > 0),
    product_width_cm           NUMERIC(6,1) CONSTRAINT chk_prod_width     CHECK (product_width_cm > 0)
);

CREATE INDEX idx_prod_category ON olist_products (product_category_name);
CREATE INDEX idx_prod_weight   ON olist_products (product_weight_g);

COMMENT ON TABLE olist_products IS
    'Catalogo de productos. product_weight_g determina el tipo de '
    'vehiculo asignado en fleet_deliveries: moto < 300g, van < 2000g, truck >= 2000g.';

-- -------------------------------------------------------------
-- 5. product_category_name_translation
--    ~71 filas — traduccion PT → EN de categorias
-- -------------------------------------------------------------
CREATE TABLE product_category_name_translation (
    product_category_name         VARCHAR(100) PRIMARY KEY,
    product_category_name_english VARCHAR(100) NOT NULL
);

COMMENT ON TABLE product_category_name_translation IS
    'Traduccion de categorias de productos del portugues al ingles.';

-- -------------------------------------------------------------
-- 6. olist_orders
--    ~99.441 filas — tabla central del dataset Olist
-- -------------------------------------------------------------
CREATE TABLE olist_orders (
    order_id                        VARCHAR(40)  PRIMARY KEY,
    customer_id                     VARCHAR(40)  NOT NULL
        REFERENCES olist_customers (customer_id),
    order_status                    VARCHAR(20)  NOT NULL
        CONSTRAINT chk_ord_status CHECK (order_status IN (
            'delivered','shipped','canceled','unavailable',
            'processing','created','approved','invoiced'
        )),
    order_purchase_timestamp        TIMESTAMP    NOT NULL,
    order_approved_at               TIMESTAMP,
    order_delivered_carrier_date    TIMESTAMP,
    order_delivered_customer_date   TIMESTAMP,
    order_estimated_delivery_date   TIMESTAMP    NOT NULL,

    -- Columna calculada: demora en horas (positivo = tarde, negativo = antes)
    -- Se puede poblar con un UPDATE despues del import, o generarse en la vista analitica
    CONSTRAINT chk_ord_dates CHECK (
        order_delivered_customer_date IS NULL
        OR order_delivered_customer_date >= order_purchase_timestamp
    )
);

CREATE INDEX idx_ord_customer  ON olist_orders (customer_id);
CREATE INDEX idx_ord_status    ON olist_orders (order_status);
CREATE INDEX idx_ord_purchase  ON olist_orders (order_purchase_timestamp);
CREATE INDEX idx_ord_delivered ON olist_orders (order_delivered_customer_date);
-- Indice parcial: solo ordenes entregadas (las mas consultadas en analisis)
CREATE INDEX idx_ord_delivered_only ON olist_orders (order_id)
    WHERE order_status = 'delivered';

COMMENT ON TABLE olist_orders IS
    'Tabla central de Olist. Contiene el ciclo de vida completo de cada orden. '
    'Las ordenes con order_status = ''delivered'' se vinculan con fleet_deliveries.';

-- -------------------------------------------------------------
-- 7. olist_order_items
--    ~112.650 filas — lineas de detalle por orden
--    PK compuesta: una orden puede tener multiples items
-- -------------------------------------------------------------
CREATE TABLE olist_order_items (
    order_id             VARCHAR(40)   NOT NULL
        REFERENCES olist_orders (order_id),
    order_item_id        SMALLINT      NOT NULL,   -- nro de linea dentro de la orden
    product_id           VARCHAR(40)   NOT NULL
        REFERENCES olist_products (product_id),
    seller_id            VARCHAR(40)   NOT NULL
        REFERENCES olist_sellers (seller_id),
    shipping_limit_date  TIMESTAMP     NOT NULL,
    price                NUMERIC(10,2) NOT NULL CONSTRAINT chk_item_price   CHECK (price > 0),
    freight_value        NUMERIC(10,2) NOT NULL CONSTRAINT chk_item_freight CHECK (freight_value >= 0),

    PRIMARY KEY (order_id, order_item_id)
);

CREATE INDEX idx_items_product ON olist_order_items (product_id);
CREATE INDEX idx_items_seller  ON olist_order_items (seller_id);

COMMENT ON TABLE olist_order_items IS
    'Detalle de productos por orden. freight_value es el costo de envio '
    'cobrado al cliente — se usa como proxy para estimar distance_km en la flota.';

-- -------------------------------------------------------------
-- 8. olist_order_reviews
--    ~99.224 filas — resenas de clientes post-entrega
-- -------------------------------------------------------------
CREATE TABLE olist_order_reviews (
    review_id               VARCHAR(40)  PRIMARY KEY,
    order_id                VARCHAR(40)  NOT NULL
        REFERENCES olist_orders (order_id),
    review_score            SMALLINT     NOT NULL
        CONSTRAINT chk_rev_score CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title    VARCHAR(100),
    review_comment_message  TEXT,                  -- texto libre (semiestructurado)
    review_creation_date    TIMESTAMP,
    review_answer_timestamp TIMESTAMP
);

CREATE INDEX idx_rev_order ON olist_order_reviews (order_id);
CREATE INDEX idx_rev_score ON olist_order_reviews (review_score);

COMMENT ON TABLE olist_order_reviews IS
    'Resenas de clientes. review_score (1-5) es la variable de impacto final: '
    'refleja el resultado percibido de la logistica. '
    'review_comment_message es texto libre — permite analisis de sentimiento.';

-- -------------------------------------------------------------
-- 9. olist_order_payments
--    ~103.886 filas — metodos y montos de pago por orden
--    Una orden puede tener multiples registros (ej. cupon + tarjeta)
-- -------------------------------------------------------------
CREATE TABLE olist_order_payments (
    order_id              VARCHAR(40)   NOT NULL
        REFERENCES olist_orders (order_id),
    payment_sequential    SMALLINT      NOT NULL,  -- nro de pago dentro de la orden
    payment_type          VARCHAR(30)   NOT NULL
        CONSTRAINT chk_pay_type CHECK (payment_type IN (
            'credit_card','boleto','voucher','debit_card','not_defined'
        )),
    payment_installments  SMALLINT      NOT NULL CONSTRAINT chk_pay_inst CHECK (payment_installments >= 0),
    payment_value         NUMERIC(10,2) NOT NULL CONSTRAINT chk_pay_val  CHECK (payment_value >= 0),

    PRIMARY KEY (order_id, payment_sequential)
);

CREATE INDEX idx_pay_type ON olist_order_payments (payment_type);

COMMENT ON TABLE olist_order_payments IS
    'Pagos asociados a cada orden. Una orden puede dividirse en multiples '
    'metodos (boleto + voucher). payment_value es el monto efectivamente pagado.';

-- =============================================================
-- VERIFICACION RAPIDA POST-IMPORT
-- Ejecutar despues de cargar los CSV con 03_import_data.sql
-- =============================================================
-- SELECT 'olist_geolocation'              AS tabla, COUNT(*) AS filas FROM olist_geolocation
-- UNION ALL
-- SELECT 'olist_customers',                          COUNT(*) FROM olist_customers
-- UNION ALL
-- SELECT 'olist_sellers',                            COUNT(*) FROM olist_sellers
-- UNION ALL
-- SELECT 'olist_products',                           COUNT(*) FROM olist_products
-- UNION ALL
-- SELECT 'product_category_name_translation',        COUNT(*) FROM product_category_name_translation
-- UNION ALL
-- SELECT 'olist_orders',                             COUNT(*) FROM olist_orders
-- UNION ALL
-- SELECT 'olist_order_items',                        COUNT(*) FROM olist_order_items
-- UNION ALL
-- SELECT 'olist_order_reviews',                      COUNT(*) FROM olist_order_reviews
-- UNION ALL
-- SELECT 'olist_order_payments',                     COUNT(*) FROM olist_order_payments
-- ORDER BY tabla;
