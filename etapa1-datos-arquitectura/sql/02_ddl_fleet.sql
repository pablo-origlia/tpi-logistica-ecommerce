-- =============================================================
-- 02_ddl_fleet.sql
-- DDL: Tablas de flota logistica sintetica
-- Base de datos: olist_logistics_db (PostgreSQL 15+)
-- Proyecto TPI — Analisis de Datos Masivos, UCASAL 2026
-- =============================================================
-- Vinculacion con Olist:
--   fleet_deliveries.order_id → olist_orders.order_id
--   fleet_deliveries.vehicle_id → fleet_vehicles.vehicle_id
--   fleet_deliveries.driver_id  → fleet_drivers.driver_id
--   fleet_incidents.order_id    → fleet_deliveries.order_id (nullable)
--
-- Orden de creacion:
--   1. fleet_vehicles   (sin FK entrante)
--   2. fleet_drivers    (FK → fleet_vehicles)
--   3. fleet_deliveries (FK → olist_orders, fleet_vehicles, fleet_drivers)
--   4. fleet_maintenance(FK → fleet_vehicles)
--   5. fleet_incidents  (FK → fleet_vehicles, fleet_deliveries)
-- =============================================================

DROP TABLE IF EXISTS fleet_incidents   CASCADE;
DROP TABLE IF EXISTS fleet_maintenance CASCADE;
DROP TABLE IF EXISTS fleet_deliveries  CASCADE;
DROP TABLE IF EXISTS fleet_drivers     CASCADE;
DROP TABLE IF EXISTS fleet_vehicles    CASCADE;

-- -------------------------------------------------------------
-- 1. fleet_vehicles
--    60 vehiculos del catalogo sintetico
-- -------------------------------------------------------------
CREATE TABLE fleet_vehicles (
    vehicle_id                  SERIAL        PRIMARY KEY,
    plate                       CHAR(8)       NOT NULL UNIQUE,   -- formato AAA-9999
    type                        VARCHAR(10)   NOT NULL
        CONSTRAINT chk_veh_type CHECK (type IN ('moto', 'van', 'truck')),
    brand                       VARCHAR(50)   NOT NULL,
    model                       VARCHAR(50)   NOT NULL,
    year                        SMALLINT      NOT NULL
        CONSTRAINT chk_veh_year CHECK (year BETWEEN 2010 AND 2017),
    capacity_kg                 SMALLINT      NOT NULL
        CONSTRAINT chk_veh_cap CHECK (capacity_kg > 0),
    fuel_type                   VARCHAR(20)   NOT NULL
        CONSTRAINT chk_veh_fuel CHECK (fuel_type IN (
            'flex','gasolina','diesel','diesel_b10','gas_natural'
        )),
    fuel_consumption_rate_lh    NUMERIC(5,2)  NOT NULL
        CONSTRAINT chk_veh_fcr CHECK (fuel_consumption_rate_lh > 0),
    status                      VARCHAR(10)   NOT NULL DEFAULT 'activo'
        CONSTRAINT chk_veh_status CHECK (status IN ('activo', 'baja'))
);

CREATE INDEX idx_veh_type   ON fleet_vehicles (type);
CREATE INDEX idx_veh_status ON fleet_vehicles (status);

COMMENT ON TABLE fleet_vehicles IS
    'Catalogo de 60 vehiculos de la flota sintetica. '
    'Tipo determina capacidad: moto=30kg, van=500kg, truck=5000kg. '
    'Formato de patente: DENATRAN 2016-2018 (AAA-9999).';
COMMENT ON COLUMN fleet_vehicles.fuel_consumption_rate_lh IS
    'Consumo de combustible en litros/hora. Calibrado desde '
    'dynamic_supply_chain_logistics_dataset.csv, escalado por tipo de vehiculo.';

-- -------------------------------------------------------------
-- 2. fleet_drivers
--    40 conductores asignados por region
-- -------------------------------------------------------------
CREATE TABLE fleet_drivers (
    driver_id              SERIAL        PRIMARY KEY,
    name                   VARCHAR(100)  NOT NULL,
    license_type           CHAR(1)       NOT NULL
        CONSTRAINT chk_drv_license CHECK (license_type IN ('A', 'B', 'C', 'E')),
        -- A = moto, B = van, C = truck rigido, E = articulado (CNH DETRAN)
        -- Nota: el script genera 'E' para trucks (license_map original).
        -- La correccion a 'C' aplica desde v1.1 en adelante.
    hire_date              DATE          NOT NULL
        CONSTRAINT chk_drv_hire CHECK (hire_date BETWEEN '2010-01-01' AND '2016-12-31'),
    region_assigned        CHAR(2)       NOT NULL
        CONSTRAINT chk_drv_region CHECK (region_assigned IN (
            'AC','AL','AM','AP','BA','CE','DF','ES','GO','MA',
            'MG','MS','MT','PA','PB','PE','PI','PR','RJ','RN',
            'RO','RR','RS','SC','SE','SP','TO'
        )),
    vehicle_id             INTEGER       NOT NULL
        REFERENCES fleet_vehicles (vehicle_id),
    driver_behavior_score  NUMERIC(4,3)  NOT NULL
        CONSTRAINT chk_drv_behavior CHECK (driver_behavior_score BETWEEN 0 AND 1),
    fatigue_score_avg      NUMERIC(4,3)  NOT NULL
        CONSTRAINT chk_drv_fatigue CHECK (fatigue_score_avg BETWEEN 0 AND 1)
);

CREATE INDEX idx_drv_region  ON fleet_drivers (region_assigned);
CREATE INDEX idx_drv_vehicle ON fleet_drivers (vehicle_id);

COMMENT ON TABLE fleet_drivers IS
    'Conductores sinteticos con nombres brasilenos. '
    'region_assigned coincide con seller_state de Olist (criterio de asignacion). '
    'Scores calibrados desde dynamic_supply_chain_logistics_dataset.csv.';
COMMENT ON COLUMN fleet_drivers.driver_behavior_score IS
    '0 = comportamiento peligroso, 1 = comportamiento optimo. '
    'Fuente: distribucion real de driver_behavior_score del dataset Kaggle.';
COMMENT ON COLUMN fleet_drivers.fatigue_score_avg IS
    '0 = fatiga extrema, 1 = sin fatiga. '
    'Fuente: distribucion real de fatigue_monitoring_score del dataset Kaggle.';

-- -------------------------------------------------------------
-- 3. fleet_deliveries
--    ~96.000 registros — tabla de vinculacion central
--    Una fila por orden de Olist con status = 'delivered'
-- -------------------------------------------------------------
CREATE TABLE fleet_deliveries (
    delivery_id              SERIAL         PRIMARY KEY,
    order_id                 VARCHAR(40)    NOT NULL UNIQUE
        REFERENCES olist_orders (order_id),
    vehicle_id               INTEGER        NOT NULL
        REFERENCES fleet_vehicles (vehicle_id),
    driver_id                INTEGER        NOT NULL
        REFERENCES fleet_drivers (driver_id),

    -- Fechas: extraidas de olist_orders para garantizar consistencia temporal
    pickup_date              TIMESTAMP      NOT NULL,   -- = order_purchase_timestamp
    carrier_pickup_date      TIMESTAMP,                 -- = order_delivered_carrier_date
    delivery_date            TIMESTAMP,                 -- = order_delivered_customer_date

    -- Metricas del trayecto (calibradas desde el dataset Kaggle)
    distance_km              NUMERIC(8,1)   NOT NULL
        CONSTRAINT chk_del_dist CHECK (distance_km BETWEEN 5 AND 2500),
    route_state              CHAR(2)        NOT NULL,   -- estado de origen = seller_state
    delivery_status          VARCHAR(10)    NOT NULL
        CONSTRAINT chk_del_status CHECK (delivery_status IN ('on_time', 'delayed')),
    eta_variation_hours      NUMERIC(6,2)   NOT NULL,   -- positivo = demora, negativo = adelanto
    loading_unloading_time_h NUMERIC(5,2)   NOT NULL
        CONSTRAINT chk_del_lut CHECK (loading_unloading_time_h >= 0),
    route_risk_level         NUMERIC(4,2)   NOT NULL
        CONSTRAINT chk_del_risk CHECK (route_risk_level BETWEEN 0 AND 10),

    CONSTRAINT chk_del_dates CHECK (
        delivery_date IS NULL OR delivery_date >= pickup_date
    )
);

-- Indices para los JOINs mas frecuentes
CREATE INDEX idx_del_order    ON fleet_deliveries (order_id);
CREATE INDEX idx_del_vehicle  ON fleet_deliveries (vehicle_id);
CREATE INDEX idx_del_driver   ON fleet_deliveries (driver_id);
CREATE INDEX idx_del_status   ON fleet_deliveries (delivery_status);
CREATE INDEX idx_del_state    ON fleet_deliveries (route_state);
CREATE INDEX idx_del_pickup   ON fleet_deliveries (pickup_date);

-- Indice compuesto para consultas de analisis por periodo y estado
CREATE INDEX idx_del_state_pickup ON fleet_deliveries (route_state, pickup_date);

COMMENT ON TABLE fleet_deliveries IS
    'Tabla de vinculacion central entre Olist y la flota sintetica. '
    'Una fila por orden entregada (order_status = ''delivered'' en olist_orders). '
    'Clave de integracion: fleet_deliveries.order_id = olist_orders.order_id.';
COMMENT ON COLUMN fleet_deliveries.distance_km IS
    'Estimada como proxy: shipping_costs (BRL) / 3.0. '
    'Coeficiente empirico ANTT 2017: mediana ~$456 BRL ≈ 152 km inter-estado. '
    'Rango forzado: 5–2500 km.';
COMMENT ON COLUMN fleet_deliveries.eta_variation_hours IS
    'Variable objetivo para el Modelo 1 (regresion). '
    'Calibrada desde eta_variation_hours del dataset Kaggle. '
    'Positivo = demora respecto al ETA estimado. Negativo = adelanto.';
COMMENT ON COLUMN fleet_deliveries.delivery_status IS
    'Variable objetivo para el Modelo 2 (clasificacion). '
    'Umbral: percentil 60 de delay_probability del dataset Kaggle.';

-- -------------------------------------------------------------
-- 4. fleet_maintenance
--    ~720 registros — historial de mantenimientos por vehiculo
--    8–15 eventos por vehiculo a lo largo de 2016–2018
-- -------------------------------------------------------------
CREATE TABLE fleet_maintenance (
    maintenance_id      SERIAL        PRIMARY KEY,
    vehicle_id          INTEGER       NOT NULL
        REFERENCES fleet_vehicles (vehicle_id),
    date                DATE          NOT NULL
        CONSTRAINT chk_mnt_date CHECK (date BETWEEN '2016-01-01' AND '2018-12-31'),
    type                VARCHAR(15)   NOT NULL
        CONSTRAINT chk_mnt_type CHECK (type IN ('preventivo', 'correctivo')),
    component           VARCHAR(50)   NOT NULL,
    cost_brl            NUMERIC(10,2) NOT NULL
        CONSTRAINT chk_mnt_cost CHECK (cost_brl > 0),
    downtime_hours      NUMERIC(6,2)  NOT NULL
        CONSTRAINT chk_mnt_down CHECK (downtime_hours >= 0),
        -- preventivo: 1–6h | correctivo: 4–48h
    mileage_at_service  INTEGER       NOT NULL
        CONSTRAINT chk_mnt_mileage CHECK (mileage_at_service >= 0)
);

CREATE INDEX idx_mnt_vehicle ON fleet_maintenance (vehicle_id);
CREATE INDEX idx_mnt_date    ON fleet_maintenance (date);
CREATE INDEX idx_mnt_type    ON fleet_maintenance (type);
-- Indice compuesto para analisis estacional (mes + tipo)
CREATE INDEX idx_mnt_month_type ON fleet_maintenance (
    CAST(EXTRACT(MONTH FROM date) AS INTEGER), type
);

COMMENT ON TABLE fleet_maintenance IS
    'Historial de mantenimientos. Patron estacional: mayor probabilidad de '
    'mantenimiento correctivo en nov–dic (×1.5) y ene–feb (×1.2), '
    'coherente con picos de demanda del e-commerce en Olist.';
COMMENT ON COLUMN fleet_maintenance.component IS
    'Componente intervenido: aceite_motor, frenos, motor, transmision, '
    'suspension, sistema_electrico, neumaticos, etc.';

-- -------------------------------------------------------------
-- 5. fleet_incidents
--    ~15% del subconjunto de ordenes demoradas
--    Registra causas operativas de demoras
-- -------------------------------------------------------------
CREATE TABLE fleet_incidents (
    incident_id             SERIAL        PRIMARY KEY,
    vehicle_id              INTEGER       NOT NULL
        REFERENCES fleet_vehicles (vehicle_id),
    date                    DATE          NOT NULL
        CONSTRAINT chk_inc_date CHECK (date BETWEEN '2016-01-01' AND '2018-12-31'),
    type                    VARCHAR(40)   NOT NULL
        CONSTRAINT chk_inc_type CHECK (type IN (
            'retraso_trafico',
            'condicion_climatica',
            'averia',
            'falla_mecanica_menor',
            'accidente'
        )),
        -- Valores sin tildes: coinciden exactamente con los generados
        -- por generate_fleet_dataset.py (incident_types, L472-473)
    disruption_likelihood   NUMERIC(4,3)  NOT NULL
        CONSTRAINT chk_inc_disrup CHECK (disruption_likelihood BETWEEN 0 AND 1),
    impact_on_delivery_h    NUMERIC(6,2)  NOT NULL
        CONSTRAINT chk_inc_impact CHECK (impact_on_delivery_h >= 0),
        -- retraso_trafico: 1–6h | condicion_climatica: 2–12h
        -- averia: 4–24h | falla_mecanica_menor: 1–8h | accidente: 8–48h
    order_id                VARCHAR(40)
        REFERENCES olist_orders (order_id)   -- nullable: no toda demora tiene incidente
);

CREATE INDEX idx_inc_vehicle ON fleet_incidents (vehicle_id);
CREATE INDEX idx_inc_date    ON fleet_incidents (date);
CREATE INDEX idx_inc_type    ON fleet_incidents (type);
CREATE INDEX idx_inc_order   ON fleet_incidents (order_id) WHERE order_id IS NOT NULL;

COMMENT ON TABLE fleet_incidents IS
    'Incidentes logisticos que causaron demoras. '
    'Representa el 15% del subconjunto de ordenes con delivery_status = ''delayed''. '
    'order_id nullable: un incidente puede afectar una entrega sin estar '
    'asociado a una orden especifica (ej. averia en deposito).';
COMMENT ON COLUMN fleet_incidents.disruption_likelihood IS
    'Probabilidad de disrupcion calculada por el sistema de monitoreo. '
    'Calibrada desde disruption_likelihood_score del dataset Kaggle.';

-- =============================================================
-- VERIFICACION RAPIDA POST-IMPORT
-- =============================================================
-- SELECT 'fleet_vehicles'   AS tabla, COUNT(*) AS filas FROM fleet_vehicles
-- UNION ALL
-- SELECT 'fleet_drivers',            COUNT(*) FROM fleet_drivers
-- UNION ALL
-- SELECT 'fleet_deliveries',         COUNT(*) FROM fleet_deliveries
-- UNION ALL
-- SELECT 'fleet_maintenance',        COUNT(*) FROM fleet_maintenance
-- UNION ALL
-- SELECT 'fleet_incidents',          COUNT(*) FROM fleet_incidents
-- ORDER BY tabla;

-- Verificacion de integridad referencial clave:
-- SELECT COUNT(*) AS ordenes_sin_entrega
-- FROM olist_orders o
-- LEFT JOIN fleet_deliveries fd ON fd.order_id = o.order_id
-- WHERE o.order_status = 'delivered' AND fd.order_id IS NULL;
-- Resultado esperado: 0
