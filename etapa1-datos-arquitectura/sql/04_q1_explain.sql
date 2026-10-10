SET client_encoding = 'UTF8';
-- 04_q1_explain.sql
-- Q1: Factores de demora por estado y tipo de vehiculo (+ congestion y clima)
-- Ejecutar: psql -U postgres -d olist_logistics_db -f 04_q1_explain.sql
--   > ..\performance\explain_sin_indices\q1_sin_idx.txt
-- (cambiar carpeta a con_indices despues de 05_indices.sql)
-- Requiere: SET track_io_timing = on
-- ============================================================

SET track_io_timing = on;

EXPLAIN (
    ANALYZE,
    BUFFERS,
    VERBOSE,
    SETTINGS,
    WAL,
    FORMAT TEXT
)
-- +-------------------------------------------------------------+
-- | CONSULTA 1                                                  |
-- | Cuales son los principales factores operativos de la flota |
-- | asociados a las entregas demoradas, por estado de Brasil?   |
-- +-------------------------------------------------------------+
-- Tablas: olist_orders, olist_customers, fleet_deliveries,
--         fleet_vehicles, fleet_drivers
-- Metricas registradas:
--   - Tiempo de ejecucion
--   - Filas procesadas vs retornadas (27 estados -> 27 filas)
--   - Tipo de JOIN (Hash Join vs Nested Loop)
--   - Uso de indices idx_ord_status, idx_del_status

SELECT
    c.customer_state                                    AS estado,
    fv.type                                             AS tipo_vehiculo,
    COUNT(fd.delivery_id)                               AS total_entregas,
    COUNT(fd.delivery_id)
        FILTER (WHERE fd.delivery_status = 'delayed')   AS entregas_demoradas,
    ROUND(
        COUNT(fd.delivery_id)
            FILTER (WHERE fd.delivery_status = 'delayed')
        * 100.0
        / NULLIF(COUNT(fd.delivery_id), 0),
    1)                                                  AS pct_demoradas,
    ROUND(AVG(fd.eta_variation_hours)::NUMERIC, 2)         AS eta_variacion_promedio_h,
    ROUND(AVG(fd.route_risk_level)::NUMERIC, 2)            AS riesgo_ruta_promedio,
    ROUND(AVG(fdr.driver_behavior_score)::NUMERIC, 3)      AS comportamiento_conductor_promedio,
    ROUND(AVG(fd.distance_km)::NUMERIC, 1)                 AS distancia_promedio_km,
    -- Nuevos predictores de contexto externo (incorporados Etapa 1)
    ROUND(AVG(fd.traffic_congestion_level)::NUMERIC, 2)    AS congestion_trafico_promedio,
    ROUND(AVG(fd.weather_condition_severity)::NUMERIC, 3)  AS severidad_clima_promedio
FROM olist_orders         o
JOIN olist_customers      c   ON c.customer_id   = o.customer_id
JOIN fleet_deliveries     fd  ON fd.order_id     = o.order_id
JOIN fleet_vehicles       fv  ON fv.vehicle_id   = fd.vehicle_id
JOIN fleet_drivers        fdr ON fdr.driver_id   = fd.driver_id
WHERE o.order_status = 'delivered'
GROUP BY
    c.customer_state,
    fv.type
HAVING COUNT(fd.delivery_id) >= 10      -- excluir combinaciones con muy pocos datos
ORDER BY
    pct_demoradas DESC,
    total_entregas DESC;

-- Interpretacion esperada:
-- Estados del nordeste (BA, PE, CE) y tipo truck mostraran mayor % demorado.;
