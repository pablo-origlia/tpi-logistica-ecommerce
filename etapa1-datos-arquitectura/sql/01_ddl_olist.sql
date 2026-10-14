SET client_encoding = 'UTF8';
-- =============================================================
-- 01_ddl_olist.sql
-- DDL: Tablas de Olist Brazilian E-Commerce Dataset
-- Base de datos: olist_logistics_db (PostgreSQL 15+)
-- Proyecto TPI — Análisis de Datos Masivos, UCASAL 2026
-- =============================================================
-- Decisiones de diseno sobre los datos originales de Olist:
--   * olist_geolocation: sin CHECK de rango geografico (el CSV trae 42 coordenadas fuera de Brasil;
--     se filtran en la preparacion de datos, Etapa 2).
--   * olist_products: product_weight_g admite 0 y NULL (el CSV trae pesos 0).
--   * olist_order_reviews: la PK es un id interno (review_pk) porque review_id esta duplicado en el CSV.
--   * olist_products incluye un registro auxiliar 'unknown_product_placeholder' que mantiene la
--     integridad referencial si algun item apuntara a un producto ausente del catalogo.
--
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
--    Sin PK única en el CSV original: el mismo zip puede tener
--    multiples coordenadas. Se usa como tabla de referencia.
-- -------------------------------------------------------------
CREATE TABLE olist_geolocation (
    geolocation_zip_code_prefix  CHAR(5)        NOT NULL,
    geolocation_lat              NUMERIC(10, 6) NOT NULL,
    geolocation_lng              NUMERIC(10, 6) NOT NULL,
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
    'Una fila por coordenada medida: un zip puede tener varias filas. '
    'El dataset original contiene 42 coordenadas fuera del bounding box de Brasil; no hay CHECK geografico '
    'y se filtran en la preparacion de datos (Etapa 2).';

-- -------------------------------------------------------------
-- 2. olist_customers
--    ~99.441 filas — un registro por orden (customer_id)
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
    'Clientes de Olist. customer_id cambia con cada pedido; '
    'customer_unique_id identifica al cliente real entre pedidos (96.096 clientes distintos).';

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
    'Vendedores registrados en Olist. seller_state es el estado de origen del envio '
    '(route_state en fleet_deliveries).';

-- -------------------------------------------------------------
-- 4. olist_products
--    32.951 productos + 1 registro auxiliar (placeholder)
-- -------------------------------------------------------------
CREATE TABLE olist_products (
    product_id                 VARCHAR(40)  PRIMARY KEY,
    product_category_name      VARCHAR(100),
    product_name_lenght        SMALLINT     CONSTRAINT chk_prod_name_len  CHECK (product_name_lenght  > 0),
    product_description_lenght INTEGER      CONSTRAINT chk_prod_desc_len  CHECK (product_description_lenght > 0),
    product_photos_qty         SMALLINT     CONSTRAINT chk_prod_photos    CHECK (product_photos_qty >= 0),
    product_weight_g           INTEGER      CONSTRAINT chk_prod_weight    CHECK (product_weight_g >= 0),
    product_length_cm          NUMERIC(6,1) CONSTRAINT chk_prod_length    CHECK (product_length_cm > 0),
    product_height_cm          NUMERIC(6,1) CONSTRAINT chk_prod_height    CHECK (product_height_cm > 0),
    product_width_cm           NUMERIC(6,1) CONSTRAINT chk_prod_width     CHECK (product_width_cm > 0)
);

CREATE INDEX idx_prod_category ON olist_products (product_category_name);
CREATE INDEX idx_prod_weight   ON olist_products (product_weight_g);

COMMENT ON TABLE olist_products IS
    'Catalogo de productos. product_weight_g determina el tipo de '
    'vehiculo asignado en fleet_deliveries: moto < 300g, van < 2000g, truck >= 2000g. '
    'Los nombres product_name_lenght y product_description_lenght conservan la ortografia del CSV original. '
    'El registro product_id=''unknown_product_placeholder'' es auxiliar: preserva la integridad referencial '
    'si algun item apuntara a un producto ausente del catalogo (en la carga final ningun item lo usa).';
COMMENT ON COLUMN olist_products.product_weight_g IS
    'Peso del producto en gramos. El dataset original contiene pesos = 0 (dato sucio) y NULL; '
    'en la preparacion de datos se imputan con la mediana de la categoria.';

-- Registro auxiliar (ver comentario de la tabla)
INSERT INTO olist_products (
    product_id, product_category_name, product_name_lenght, product_description_lenght,
    product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm
) VALUES ('unknown_product_placeholder', 'unknown', NULL, NULL, NULL, NULL, NULL, NULL, NULL)
ON CONFLICT (product_id) DO NOTHING;

-- -------------------------------------------------------------
-- 5. product_category_name_translation
--    ~71 filas — traduccion PT → EN de categorias
-- -------------------------------------------------------------
CREATE TABLE product_category_name_translation (
    product_category_name         VARCHAR(100) PRIMARY KEY,
    product_category_name_english VARCHAR(100) NOT NULL
);

COMMENT ON TABLE product_category_name_translation IS
    'Traducción de categorías de productos del portugués al ingles.';

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
    'Detalle de productos por orden. freight_value es el costo de envio cobrado al cliente.';

-- -------------------------------------------------------------
-- 8. olist_order_reviews
--    ~99.224 filas — resenas de clientes post-entrega
-- -------------------------------------------------------------
CREATE TABLE olist_order_reviews (
    review_id               VARCHAR(40)  NOT NULL,        -- con duplicados en el CSV: no es clave
    order_id                VARCHAR(40)  NOT NULL
        REFERENCES olist_orders (order_id),
    review_score            SMALLINT     NOT NULL
        CONSTRAINT chk_rev_score CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title    VARCHAR(100),
    review_comment_message  TEXT,                  -- texto libre (semiestructurado)
    review_creation_date    TIMESTAMP,
    review_answer_timestamp TIMESTAMP,
    review_pk               SERIAL       PRIMARY KEY      -- clave interna
);

CREATE INDEX idx_rev_order     ON olist_order_reviews (order_id);
CREATE INDEX idx_rev_score     ON olist_order_reviews (review_score);
CREATE INDEX idx_rev_review_id ON olist_order_reviews (review_id);

COMMENT ON TABLE olist_order_reviews IS
    'Reseñas de clientes. review_score (1-5) es la variable de impacto final: '
    'refleja el resultado percibido de la logística. '
    'review_comment_message es texto libre — permite análisis de sentimiento.';
COMMENT ON COLUMN olist_order_reviews.review_pk IS
    'Clave primaria interna (SERIAL). review_id tiene 814 duplicados en el dataset original y no sirve como clave.';
COMMENT ON COLUMN olist_order_reviews.review_id IS
    'ID de resena del dataset Olist. Duplicado en el CSV: usar review_pk para identificar filas.';

-- -------------------------------------------------------------
-- 9. olist_order_payments
--    ~103.886 filas — métodos y montos de pago por orden
--    Una orden puede tener multiples registros (ej. cupón + tarjeta)
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
    'métodos (boleto + voucher). payment_value es el monto efectivamente pagado.';

-- =============================================================
-- DDL AUDIT — verificacion de estructura del schema Olist
-- =============================================================
-- Se ejecuta sin datos. Detecta problemas de schema ANTES del
-- import, evitando tener que recargar 1,6 millones de registros.
-- Resultado esperado en cada consulta: valor = esperado.
-- =============================================================

-- 1. Tablas creadas
SELECT
    COUNT(*)                        AS tablas_olist_creadas,
    9                               AS esperado,
    CASE WHEN COUNT(*) = 9
         THEN 'OK' ELSE 'ERROR' END AS resultado
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'olist_geolocation','olist_customers','olist_sellers',
    'olist_products','product_category_name_translation',
    'olist_orders','olist_order_items',
    'olist_order_reviews','olist_order_payments'
  );

-- 2. Indices criticos del DDL verificados por nombre
--    (el conteo total varia si ya se ejecuto 05_indices.sql en corridas anteriores)
SELECT
    indexname                       AS indice,
    'OK'                            AS resultado
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
    'idx_geo_zip','idx_geo_state',
    'idx_cust_zip','idx_cust_state','idx_cust_uid',
    'idx_sel_zip','idx_sel_state',
    'idx_prod_category','idx_prod_weight',
    'idx_ord_customer','idx_ord_status','idx_ord_purchase',
    'idx_ord_delivered','idx_ord_delivered_only',
    'idx_items_product','idx_items_seller',
    'idx_rev_order','idx_rev_score','idx_rev_review_id',
    'idx_pay_type'
  )
UNION ALL
SELECT
    'FALTANTE: ' || idx             AS indice,
    'ERROR: indice del DDL no creado' AS resultado
FROM (VALUES
    ('idx_geo_zip'),('idx_geo_state'),
    ('idx_cust_zip'),('idx_cust_state'),('idx_cust_uid'),
    ('idx_sel_zip'),('idx_sel_state'),
    ('idx_prod_category'),('idx_prod_weight'),
    ('idx_ord_customer'),('idx_ord_status'),('idx_ord_purchase'),
    ('idx_ord_delivered'),('idx_ord_delivered_only'),
    ('idx_items_product'),('idx_items_seller'),
    ('idx_rev_order'),('idx_rev_score'),('idx_rev_review_id'),
    ('idx_pay_type')
) AS esperados(idx)
WHERE idx NOT IN (
    SELECT indexname FROM pg_indexes WHERE schemaname = 'public'
)
ORDER BY resultado DESC, indice;
-- Resultado esperado: 20 filas con resultado=OK, 0 filas con ERROR.

-- 3. Verificar que olist_geolocation no tiene CHECKs de rango geografico
SELECT
    COUNT(*)                        AS checks_geograficos,
    0                               AS esperado,
    CASE WHEN COUNT(*) = 0
         THEN 'OK' ELSE 'ERROR: hay checks geograficos' END AS resultado
FROM pg_constraint
WHERE conname IN ('chk_geo_lat', 'chk_geo_lng');

-- 4. Verificar definicion del CHECK de product_weight_g
SELECT
    conname                         AS constraint_name,
    pg_get_constraintdef(oid)       AS definicion,
    CASE WHEN pg_get_constraintdef(oid) LIKE '%>= 0%'
         THEN 'OK' ELSE 'ERROR: definicion incorrecta' END AS resultado
FROM pg_constraint
WHERE conname = 'chk_prod_weight';

-- 5. Verificar que review_pk existe como columna en olist_order_reviews
SELECT
    COUNT(*)                        AS columna_review_pk_existe,
    1                               AS esperado,
    CASE WHEN COUNT(*) = 1
         THEN 'OK' ELSE 'ERROR: review_pk no fue creada' END AS resultado
FROM information_schema.columns
WHERE table_name = 'olist_order_reviews'
  AND column_name = 'review_pk';

-- 6. Verificar que review_pk es la PK de olist_order_reviews
SELECT
    conname                         AS pk_name,
    pg_get_constraintdef(oid)       AS definicion,
    CASE WHEN pg_get_constraintdef(oid) LIKE '%review_pk%'
         THEN 'OK' ELSE 'ERROR: PK no apunta a review_pk' END AS resultado
FROM pg_constraint
WHERE conrelid = 'olist_order_reviews'::regclass
  AND contype = 'p';

-- 7. Verificar que unknown_product_placeholder fue insertado
SELECT
    COUNT(*)                        AS placeholder_existe,
    1                               AS esperado,
    CASE WHEN COUNT(*) = 1
         THEN 'OK' ELSE 'ERROR: placeholder no insertado' END AS resultado
FROM olist_products
WHERE product_id = 'unknown_product_placeholder';

-- 8. Resumen: todas las verificaciones en una vista
SELECT
    verificacion, esperado, resultado
FROM (
    VALUES
    ('tablas_olist_creadas',
     '9',
     (SELECT CASE WHEN COUNT(*) = 9 THEN 'OK' ELSE 'ERROR: ' || COUNT(*)::TEXT END
      FROM information_schema.tables
      WHERE table_schema='public'
        AND table_name IN ('olist_geolocation','olist_customers','olist_sellers',
            'olist_products','product_category_name_translation','olist_orders',
            'olist_order_items','olist_order_reviews','olist_order_payments'))),
    ('indices_DDL_olist_presentes',
     '20 indices clave',
     (SELECT CASE WHEN COUNT(*) = 20 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT || ' de 20 indices DDL presentes' END
      FROM pg_indexes WHERE schemaname='public'
        AND indexname IN (
            'idx_geo_zip','idx_geo_state','idx_cust_zip','idx_cust_state','idx_cust_uid',
            'idx_sel_zip','idx_sel_state','idx_prod_category','idx_prod_weight',
            'idx_ord_customer','idx_ord_status','idx_ord_purchase',
            'idx_ord_delivered','idx_ord_delivered_only',
            'idx_items_product','idx_items_seller',
            'idx_rev_order','idx_rev_score','idx_rev_review_id','idx_pay_type'))),
    ('sin_checks_geograficos',
     '0',
     (SELECT CASE WHEN COUNT(*) = 0 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT || ' checks geo activos' END
      FROM pg_constraint WHERE conname IN ('chk_geo_lat','chk_geo_lng'))),
    ('check_weight_correcto',
     '>= 0',
     (SELECT CASE WHEN pg_get_constraintdef(oid) LIKE '%>= 0%' THEN 'OK'
                  ELSE 'ERROR: ' || pg_get_constraintdef(oid) END
      FROM pg_constraint WHERE conname = 'chk_prod_weight')),
    ('review_pk_creada',
     'SI',
     (SELECT CASE WHEN COUNT(*) = 1 THEN 'OK' ELSE 'ERROR: columna no existe' END
      FROM information_schema.columns
      WHERE table_name='olist_order_reviews' AND column_name='review_pk')),
    ('pk_apunta_a_review_pk',
     'SI',
     (SELECT CASE WHEN pg_get_constraintdef(oid) LIKE '%review_pk%' THEN 'OK'
                  ELSE 'ERROR: ' || pg_get_constraintdef(oid) END
      FROM pg_constraint WHERE conrelid='olist_order_reviews'::regclass AND contype='p')),
    ('placeholder_insertado',
     'SI',
     (SELECT CASE WHEN COUNT(*) = 1 THEN 'OK' ELSE 'ERROR: no existe' END
      FROM olist_products WHERE product_id='unknown_product_placeholder'))
) AS t(verificacion, esperado, resultado)
ORDER BY verificacion;
-- Si alguna fila muestra ERROR: NO ejecutar 03_import_data.sql hasta resolverlo.
