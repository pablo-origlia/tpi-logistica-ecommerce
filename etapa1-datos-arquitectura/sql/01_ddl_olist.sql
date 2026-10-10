SET client_encoding = 'UTF8';
-- =============================================================
-- 01_ddl_olist.sql
-- DDL: Tablas de Olist Brazilian E-Commerce Dataset
-- Base de datos: olist_logistics_db (PostgreSQL 15+)
-- Proyecto TPI — Análisis de Datos Masivos, UCASAL 2026
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
--    Sin PK única en el CSV original: el mismo zip puede tener
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
    'Coordenadas geográficas por prefijo de CEP brasileño. '
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
    'Clientes de Olist. customer_id es el ID de orden (varía por pedido); '
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
    'asignación de conductor en fleet_drivers (vinculación ficticia).';

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
    'vehículo asignado en fleet_deliveries: moto < 300g, van < 2000g, truck >= 2000g.';

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

    -- Columna calculada: demora en horas (positivo = tarde, negativo = antes)
    -- Se puede poblar con un UPDATE después del import, o generarse en la vista analítica
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
    'Detalle de productos por orden. freight_value es el costo de envío '
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
    'Reseñas de clientes. review_score (1-5) es la variable de impacto final: '
    'refleja el resultado percibido de la logística. '
    'review_comment_message es texto libre — permite análisis de sentimiento.';

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
-- CORRECCIONES DE CALIDAD DEL DATASET OLIST
-- =============================================================
-- El dataset Olist tiene 4 problemas conocidos que rompen los
-- constraints del DDL original. Se corrigen aqui — antes del
-- import — para que 03_import_data.sql corra sin errores.
-- Documentacion detallada: docs/diccionario_datos_v2.xlsx
-- =============================================================

-- =============================================================
-- FIX 1: olist_geolocation — coordenadas fuera del bounding box Brasil
-- =============================================================
-- PROBLEMA:
--   El dataset Olist contiene coordenadas geograficas erroneas (ej: zip SP
--   con lat=28, lng=-15 que apunta a Islas Canarias, Espana).
--   Es un problema conocido y documentado del dataset original.
--
-- SOLUCION ELEGIDA: eliminar el CHECK geografico
--   Razon: la validacion geografica es una tarea de LIMPIEZA (Etapa 2),
--   no de integridad estructural. La BD acepta los datos crudos y el
--   notebook de limpieza filtra/imputa las coordenadas invalidas.
--   Una alternativa (BETWEEN -90 AND 90) acepta cualquier coordenada del
--   planeta sin agregar valor — preferimos documentar el problema.
--
-- IMPACTO: ninguno en joins ni en logica de negocio.
--   Los analisis geoespaciales de Etapa 2 excluiran coordenadas invalidas.

ALTER TABLE olist_geolocation DROP CONSTRAINT IF EXISTS chk_geo_lat;
ALTER TABLE olist_geolocation DROP CONSTRAINT IF EXISTS chk_geo_lng;

COMMENT ON TABLE olist_geolocation IS
    'Coordenadas por prefijo de CEP brasileno. '
    'ATENCION: el dataset original contiene coordenadas fuera del bounding '
    'box de Brasil (problema conocido). Los checks geograficos fueron '
    'eliminados intencionalmente — la validacion y limpieza se realiza '
    'en Etapa 2 (notebook 01_limpieza.ipynb).';


-- =============================================================
-- FIX 2: olist_products — product_weight_g = 0
-- =============================================================
-- PROBLEMA:
--   Algunos productos tienen product_weight_g = 0 en el CSV original.
--   Peso = 0 es un dato sucio (no existe un producto sin peso).
--   Nuestro CHECK original era: product_weight_g > 0 (rechazaba el 0).
--
-- SOLUCION ELEGIDA: permitir >= 0 y NULL, documentar para Etapa 2
--   Razon: preferimos ingestar el dato crudo y tratar el 0 como
--   "peso faltante o no registrado" en la limpieza.
--   NO usamos solo IS NULL porque el CSV ya trae el 0 explicitamente.
--
-- EFECTO EN LOGICA DE NEGOCIO:
--   En fleet_deliveries, weight_g=0 asignaria el vehiculo como 'moto'
--   (la condicion < 300g incluye el 0). Esto se documenta en Etapa 2
--   y esos productos se excluyen o imputan antes de entrenar los modelos.

ALTER TABLE olist_products DROP CONSTRAINT IF EXISTS chk_prod_weight;
ALTER TABLE olist_products
    ADD CONSTRAINT chk_prod_weight
    CHECK (product_weight_g >= 0 OR product_weight_g IS NULL);

COMMENT ON COLUMN olist_products.product_weight_g IS
    'Peso del producto en gramos. '
    'El dataset original contiene registros con weight_g = 0 (dato sucio). '
    'Tratamiento en Etapa 2: imputar con la mediana de la categoria '
    'o excluir del dataset analitico segun criterio del analisis.';


-- =============================================================
-- FIX 3: olist_order_items — FK a productos inexistentes
-- =============================================================
-- PROBLEMA:
--   Hay order_items que referencian product_ids que NO existen en
--   olist_products. Son productos que Olist elimino o anonimizo
--   despues de que las ordenes fueron registradas.
--
-- SOLUCION ELEGIDA: producto placeholder 'unknown'
--   Razon: mantener la FK intacta preserva la integridad referencial.
--   La solucion propuesta originalmente (eliminar la FK) es la peor
--   opcion — perdemos la garantia de consistencia en todos los joins.
--   Un placeholder documentado es la practica estandar en DW/ETL.
--
-- ALTERNATIVA DESCARTADA: hacer la FK DEFERRABLE o SET NULL
--   Requeriria cambiar el tipo de columna product_id en order_items,
--   complicando los joins sin beneficio real para el analisis.

INSERT INTO olist_products (
    product_id,
    product_category_name,
    product_name_lenght,
    product_description_lenght,
    product_photos_qty,
    product_weight_g,
    product_length_cm,
    product_height_cm,
    product_width_cm
) VALUES (
    'unknown_product_placeholder',   -- product_id ficticio
    'unknown',                       -- categoria desconocida
    NULL, NULL, NULL,                -- campos opcionales: NULL
    NULL,                            -- weight_g: NULL (desconocido)
    NULL, NULL, NULL
)
ON CONFLICT (product_id) DO NOTHING; -- idempotente: no falla si ya existe

-- Hacer la FK tolerante a los product_ids fuera del catalogo:
-- Cambiar referencias huerfanas al placeholder antes del COPY de items
-- (esto se ejecuta DESPUES de cargar products y ANTES de cargar items)

COMMENT ON TABLE olist_products IS
    'Catalogo de productos. product_weight_g determina el tipo de '
    'vehiculo asignado en fleet_deliveries: moto < 300g, van < 2000g, truck >= 2000g. '
    'El registro product_id=''unknown_product_placeholder'' es un placeholder '
    'para order_items que referencian productos eliminados del catalogo original.';


-- =============================================================
-- FIX 4: olist_order_reviews — review_id duplicados en el CSV
-- =============================================================
-- PROBLEMA:
--   El CSV de reviews contiene review_ids duplicados (mismo review_id,
--   distinto order_id). Es un bug conocido del dataset Olist.
--
-- SOLUCION PROPUESTA ORIGINAL (PK compuesta review_id + order_id):
--   INCORRECTA — no garantiza unicidad real y complica los joins.
--   Un review deberia identificarse por review_id solo.
--
-- SOLUCION ELEGIDA: quitar la PK de review_id, usar SERIAL interno
--   Razon: el review_id del CSV no es confiable como PK.
--   Usamos un id interno (review_pk) como PK real y guardamos
--   review_id como dato (con indice para busqueda, no unicidad).
--   Esto preserva todos los datos sin perder ninguna resena.
--
-- ALTERNATIVA DESCARTADA: cargar en staging + INSERT DISTINCT
--   Mas complejo de implementar en psql puro. La solucion del SERIAL
--   es mas limpia y directa.

-- Eliminar la PK actual basada en review_id
ALTER TABLE olist_order_reviews DROP CONSTRAINT IF EXISTS olist_order_reviews_pkey;

-- Agregar columna de PK interna (si no existe)
ALTER TABLE olist_order_reviews
    ADD COLUMN IF NOT EXISTS review_pk SERIAL;

-- Establecer la nueva PK en la columna interna
ALTER TABLE olist_order_reviews
    ADD CONSTRAINT olist_order_reviews_pkey PRIMARY KEY (review_pk);

-- review_id pasa a ser un campo indexado (no unico) para busqueda
DROP INDEX IF EXISTS idx_rev_id;
CREATE INDEX idx_rev_review_id ON olist_order_reviews (review_id);

COMMENT ON COLUMN olist_order_reviews.review_pk IS
    'Clave primaria interna (SERIAL). '
    'El review_id original del dataset Olist tiene duplicados — no es '
    'confiable como PK. Se preserva como campo indexado para busqueda.';

COMMENT ON COLUMN olist_order_reviews.review_id IS
    'ID de resena del dataset Olist original. '
    'ATENCION: el CSV contiene duplicados (bug conocido del dataset). '
    'Usar review_pk como clave primaria para joins internos.';

-- =============================================================
-- DDL AUDIT — verificacion de estructura del schema Olist
-- =============================================================
-- Se ejecuta sin datos. Detecta problemas de schema ANTES del
-- import, evitando tener que recargar 1.6M registros.
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

-- 3. Verificar que chk_geo_lat y chk_geo_lng fueron ELIMINADOS
SELECT
    COUNT(*)                        AS checks_geo_eliminados,
    0                               AS esperado,
    CASE WHEN COUNT(*) = 0
         THEN 'OK' ELSE 'ERROR: checks geograficos NO eliminados' END AS resultado
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
    ('checks_geo_eliminados',
     '0',
     (SELECT CASE WHEN COUNT(*) = 0 THEN 'OK'
                  ELSE 'ERROR: ' || COUNT(*)::TEXT || ' checks geo activos' END
      FROM pg_constraint WHERE conname IN ('chk_geo_lat','chk_geo_lng'))),
    ('check_weight_correcto',
     '>= 0 OR NULL',
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
