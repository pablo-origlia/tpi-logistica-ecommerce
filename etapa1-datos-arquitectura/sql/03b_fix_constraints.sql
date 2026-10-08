SET client_encoding = 'UTF8';
-- =============================================================
-- 03b_fix_constraints.sql
-- Correcciones de constraints e integridad post-import
-- Base de datos: olist_logistics_db (PostgreSQL 15+)
-- Proyecto TPI — Analisis de Datos Masivos, UCASAL 2026
-- =============================================================
-- CUANDO EJECUTAR:
--   Si 03_import_data.sql termino con errores, correr este script
--   y luego repetir el import desde cero (DROP + recrear tablas).
--
-- MEJOR FLUJO:
--   1. psql -f 01_ddl_olist.sql        <- crea tablas
--   2. psql -f 02_ddl_fleet.sql        <- crea tablas flota
--   3. psql -f 03b_fix_constraints.sql <- ajusta constraints ANTES del import
--   4. psql -f 03_import_data.sql      <- importa datos
--   5. psql -f 03c_post_import.sql     <- limpieza y validacion post-import
--
-- CONTEXTO DE CADA FIX:
--   Estos errores son problemas conocidos del dataset Olist, no errores
--   de nuestro DDL. Los documentamos para la presentacion de Etapa 1
--   como parte del analisis de calidad de datos (anticipa Etapa 2).
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
-- VERIFICACION DE FIXES
-- =============================================================
-- Confirmar que los constraints fueron modificados correctamente:
SELECT
    conname                AS constraint_name,
    contype                AS tipo,
    pg_get_constraintdef(oid) AS definicion
FROM pg_constraint
WHERE conrelid IN (
    'olist_geolocation'::regclass,
    'olist_products'::regclass,
    'olist_order_reviews'::regclass
)
ORDER BY conrelid::text, conname;
