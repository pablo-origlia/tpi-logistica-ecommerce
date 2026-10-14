-- =====================================================================
-- 03d_sanidad_flota.sql  (solo lectura)
-- Chequeos de sensatez de la flota sintética. Ejecutar tras 03_import_data.sql.
-- psql -U postgres -d olist_logistics_db -f 03d_sanidad_flota.sql
-- =====================================================================
\pset format aligned

\echo '--- 1) Mezcla de mantenimiento (esperado: preventivos > correctivos, ~25-40 por ciento correctivos)'
SELECT type, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       ROUND(AVG(cost_brl)) AS costo_prom, ROUND(AVG(downtime_hours), 1) AS downtime_prom_h
FROM fleet_maintenance GROUP BY type ORDER BY type;

\echo '--- 2) Cobertura de incidentes: % de órdenes tardías y a tiempo con incidente'
SELECT d.delivery_status,
       COUNT(*)                                             AS entregas,
       COUNT(DISTINCT i.order_id)                           AS con_incidente,
       ROUND(100.0 * COUNT(DISTINCT i.order_id) / COUNT(*), 1) AS pct_con_incidente
FROM fleet_deliveries d LEFT JOIN fleet_incidents i USING (order_id)
GROUP BY d.delivery_status ORDER BY d.delivery_status;

\echo '--- 3) Kilometraje máximo por vehículo (esperado: del orden de 100-250 mil)'
SELECT vehicle_id, MAX(mileage_at_service) AS km_max
FROM fleet_maintenance GROUP BY vehicle_id ORDER BY km_max DESC LIMIT 5;

\echo '--- 4) Reparto de entregas por conductor (esperado: sin extremos; todos los conductores con cientos de entregas)'
SELECT MIN(n) AS min_entregas,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY n) AS mediana,
       MAX(n) AS max_entregas, COUNT(*) AS conductores
FROM (SELECT driver_id, COUNT(*) n FROM fleet_deliveries GROUP BY driver_id) x;

\echo '--- 5) Demora por tipo de vehículo (el tipo se asigna por peso: no es causal)'
SELECT v.type, COUNT(*) AS entregas,
       ROUND(100.0 * AVG((d.delivery_status = 'delayed')::INT), 1) AS pct_demora
FROM fleet_deliveries d JOIN fleet_vehicles v USING (vehicle_id)
GROUP BY v.type ORDER BY v.type;

\echo '--- 6) Vehículos sin ninguna entrega (esperado: solo los 5 en baja)'
SELECT v.vehicle_id, v.type, v.status
FROM fleet_vehicles v LEFT JOIN fleet_deliveries d USING (vehicle_id)
WHERE d.vehicle_id IS NULL ORDER BY 1;
