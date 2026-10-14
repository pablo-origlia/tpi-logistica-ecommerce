# Informe de calidad de datos — Etapa 2

*TPI Análisis de Datos Masivos · Maestría en Ciencias de Datos, UCASAL 2026 · base `olist_logistics_db` (PostgreSQL)*

Este informe documenta el diagnóstico de calidad de los datos, las decisiones de preparación que se tomaron y el volumen de datos que sobrevive a cada paso. Las cifras provienen de `docs/diagnostico_calidad.txt` (salida de `sql/01_diagnostico_calidad.sql`) y de `notebooks/01_limpieza.ipynb`.

---

## 1. Método

El diagnóstico es un único script de solo lectura (`01_diagnostico_calidad.sql`, 2,5 s de ejecución) que devuelve una tabla con una fila por chequeo: dimensión, descripción, registros afectados, total, porcentaje y decisión. Cubre siete dimensiones: nulos, duplicados, inconsistencias, categóricas, valores extremos, integridad referencial y fechas.

**Resultado: 52 chequeos, 29 con hallazgos.** Los 23 restantes son controles de coherencia y de rango que deben dar cero y dan cero (sección 3).

---

## 2. Hallazgos y decisiones

| Dimensión | Hallazgo | Afectados | Total | % | Decisión |
|---|---|---:|---:|---:|---|
| Nulos | Órdenes `delivered` sin fecha de entrega | 8 | 96.478 | 0,008 | Excluir del dataset analítico |
| Nulos | Órdenes `delivered` sin fecha de despacho | 2 | 96.478 | 0,002 | Excluir (no se puede calcular el tiempo de despacho) |
| Nulos | Productos sin categoría | 610 | 32.952 | 1,85 | Imputar `sin_categoria` |
| Nulos | Productos sin peso | 3 | 32.952 | 0,009 | Imputar con la mediana de la categoría |
| Nulos | Reseñas sin comentario | 58.247 | 99.224 | 58,70 | Normal: dato opcional; no se imputa |
| Duplicados | `review_id` repetidos | 814 | 99.224 | 0,82 | Usar `review_pk`; se toma la última reseña por orden |
| Duplicados | Órdenes con más de 1 reseña | 547 | 98.673 | 0,55 | Agregar a una reseña por orden (la más reciente) |
| Duplicados | Órdenes con más de 1 ítem | 9.803 | 98.666 | 9,94 | Agregar los ítems a nivel orden |
| Duplicados | Órdenes con más de 1 vendedor | 1.278 | 98.666 | 1,30 | Tomar el vendedor del ítem 1 como origen del envío |
| Duplicados | Órdenes con más de 1 pago | 2.961 | 99.440 | 2,98 | Sumar los pagos; método del pago 1 |
| Duplicados | Clientes recurrentes (`customer_unique_id` con más de un `customer_id`) | 2.997 | 96.096 | 3,12 | No es un error: `customer_id` cambia por orden |
| Duplicados | Prefijos de CEP con múltiples coordenadas | 17.972 | 19.015 | 94,52 | Colapsar a un centroide (mediana) por CEP |
| Inconsistencias | Compra posterior al despacho | 166 | 96.478 | 0,17 | Excluir (secuencia temporal imposible) |
| Inconsistencias | Despacho posterior a la entrega | 23 | 96.478 | 0,02 | Excluir (secuencia temporal imposible) |
| Inconsistencias | Ítems con `freight_value = 0` | 383 | 112.650 | 0,34 | Conservar (posible envío gratuito) |
| Inconsistencias | Pagos con valor 0 | 9 | 103.886 | 0,009 | Marcar |
| Categóricas | Categorías de producto sin traducción al inglés (`pc_gamer`, `portateis_cozinha_e_preparadores_de_alimentos`, `unknown`) | 3 | 74 | 4,05 | Traducción manual o `sin_categoria` |
| Categóricas | `payment_type = not_defined` | 3 | 103.886 | 0,003 | Agrupar en `otro` |
| Valores extremos | Peso = 0 | 4 | 32.952 | 0,012 | Imputar con la mediana de la categoría |
| Valores extremos | Peso mayor que Q3 + 3·IQR | 3.073 | 32.952 | 9,33 | Conservar (pesos reales) |
| Valores extremos | Flete mayor que Q3 + 3·IQR | 5.538 | 112.650 | 4,92 | Conservar y marcar (fletes altos en regiones remotas) |
| Valores extremos | Tiempo de entrega mayor a 60 días | 306 | 96.476 | 0,32 | Conservar y marcar |
| Valores extremos | `eta_variation_hours` en los límites del rango (−168 o 336) | 6.208 | 96.470 | 6,44 | Informativo: la variable está acotada por el generador |
| Valores extremos | `distance_km` en el piso de 5 km | 567 | 96.470 | 0,59 | Informativo: entregas dentro de una misma zona |
| Geografía | Coordenadas fuera del bounding box de Brasil | 42 | 1.000.163 | 0,004 | Filtrar al construir el centroide por CEP |
| Geografía | Clientes con CEP sin coordenadas | 278 | 99.441 | 0,28 | `distancia_haversine_km` nula; `distance_km` usa el centroide del estado |
| Integridad | Órdenes sin ítems | 775 | 99.441 | 0,78 | Excluir (sin peso ni flete) |
| Integridad | Órdenes `delivered` sin reseña | 646 | 96.478 | 0,67 | Conservar con `review_score` nulo; excluir solo de los KPIs de satisfacción |
| Integridad | Órdenes `delivered` sin registro en `fleet_deliveries` | 8 | 96.478 | 0,008 | Excluir (INNER JOIN en el dataset analítico) |

---

## 3. Controles de coherencia (sin hallazgos)

Los siguientes chequeos dan cero afectados:

- **Catálogos y formatos:** `order_status` fuera de catálogo, `customer_state` fuera de las 27 siglas, CEP de longitud distinta de 5.
- **Fechas:** órdenes fuera del rango de Olist, `approved_at` anterior a la compra, fecha estimada anterior a la compra, mantenimientos fuera del período 2016–2018, mantenimientos anteriores al año del vehículo, incidentes fuera del viaje, conductores contratados después de su primera entrega.
- **Montos:** ítems con precio 0.
- **Integridad de la flota:**
  - La fecha de entrega de la flota coincide con la de Olist.
  - El vehículo asignado respeta la regla de peso.
  - El conductor de la entrega maneja el vehículo de la entrega y su licencia lo habilita.
  - Ningún vehículo tiene más de un conductor.
  - No hay entregas ni conductores en vehículos dados de baja.
  - Toda entrega de la flota corresponde a una orden `delivered`.
- **Definición de demora:** `delivery_status` coincide siempre con la demora real de Olist.
- **Rangos declarados:** `eta_variation_hours` dentro de [−168, 336] y `distance_km` dentro de [5, 6000].
- **Producto auxiliar:** ningún ítem apunta a `unknown_product_placeholder`.

---

## 4. Transformaciones aplicadas

El dataset analítico (`vw_dataset_analitico` y su copia materializada `mv_dataset_analitico`) tiene **una fila por orden entregada** y 49 columnas. Las tablas de ítems, pagos y reseñas son relaciones 1 a N: unirlas sin agregar multiplicaría las filas (el 9,9 % de las órdenes tiene más de un ítem) e inflaría los indicadores.

1. **Selección:** órdenes `delivered` con fecha de entrega y de despacho, con secuencia temporal consistente, con registro en la flota y con al menos un ítem.
2. **Agregaciones 1:N:** ítems (conteo, suma de precio, flete y peso), pagos (suma, cuotas máximas, método del primer pago) y reseña más reciente.
3. **Peso:** 0, nulo o producto auxiliar se reemplazan por la mediana de la categoría (o la mediana global) y se deja `flag_peso_imputado` (22 órdenes).
4. **Geografía:** 1.000.163 puntos se reducen a un centroide (mediana) por CEP, dentro del bounding box de Brasil. Con ellos se calcula la distancia haversine entre vendedor y cliente.
5. **Variables derivadas:** `dias_entrega_total`, `dias_hasta_despacho`, `dias_transito`, `dias_prometidos`, `dias_demora_olist`, `demora_olist`, `mismo_estado`, `flete_sobre_precio`, `indice_fatiga`, `resena_negativa` y `dias_desde_ult_mant` (días entre el último mantenimiento del vehículo y la compra).
6. **Vistas auxiliares:** `vw_flota_mes_tipo` (mes × tipo de vehículo) y `vw_conductor` (perfil por conductor, con su vehículo y su tipo).
7. **Outliers:** se marcan, no se eliminan (sección 6).

La definición de demora es una sola: `demora_olist` (entrega posterior a la fecha prometida). `delivery_status` de la flota la replica por construcción.

---

## 5. Impacto en el volumen

| Paso | Filas | Pérdida | % sobre el total |
|---|---:|---:|---:|
| Órdenes totales | 99.441 | — | 100,00 |
| `status = delivered` | 96.478 | −2.963 | 97,02 |
| Con fecha de entrega y de despacho | 96.469 | −9 | 97,01 |
| Con fechas consistentes | 96.281 | −188 | 96,82 |
| **Dataset final** (con flota e ítems) | **96.281** | 0 | **96,82** |

**Controles del dataset final:** una fila por orden (96.281 órdenes distintas); período del 15-09-2016 al 29-08-2018; 22 órdenes con peso imputado.

**Nulos remanentes:**

| Variable | Nulos | % | Motivo |
|---|---:|---:|---|
| `review_score`, `tiene_comentario`, `resena_negativa` | 645 | 0,67 | Órdenes sin reseña |
| `distancia_haversine_km` | 479 | 0,50 | CEP del vendedor o del cliente sin coordenadas |
| `dias_desde_ult_mant` | 2.120 | 2,20 | Órdenes anteriores al primer mantenimiento de su vehículo |
| `pago_total`, `cuotas_max` | 1 | 0,00 | Orden sin pagos |

---

## 6. Valores extremos

Se marcan con la regla de Tukey (1,5 · IQR) las variables continuas sin cota. Los flags (`out_*`) se agregan al exportar el dataset y no eliminan ninguna fila.

| Variable | Outliers | % |
|---|---:|---:|
| `dias_entrega_total` | 4.892 | 5,08 |
| `dias_demora_olist` | 4.859 | 5,05 |
| `distance_km` | 7.480 | 7,77 |
| `flete_total` | 9.668 | 10,04 |
| `peso_total_g` | 13.515 | 14,04 |
| `precio_total` | 7.651 | 7,95 |

No se marcan `eta_variation_hours` (acotada y censurada en los límites) ni las variables simuladas de rango fijo y forma de U (tráfico, clima, riesgo): para ellas la regla de Tukey no es aplicable. Por ejemplo, para el tráfico (escala 0–10) los límites resultan −9,1 y 19,1, fuera de su rango posible.

---

## 7. Variables reales y simuladas

Las variables de Olist (fechas, estados, pesos, precios, fletes, reseñas, pagos y coordenadas) son reales. De la flota, `distance_km`, `delivery_status` y `eta_variation_hours` se derivan de datos reales; tráfico, clima, riesgo de ruta, conductor, mantenimiento e incidentes son simulados y condicionados a señales reales.

---

## 8. Limitaciones

- **Las asociaciones entre las variables simuladas y la demora real están impuestas por el generador.** Describen un escenario, no evidencia empírica.
- **Fuga de información al modelar:** tráfico, clima y riesgo se generan condicionados al resultado y no se conocerían al comprar; `n_incidentes` y `horas_impacto_incidentes` se conocen después de la entrega.
- `eta_variation_hours` está acotada a [−168, 336] h: el 5,14 % de las entregas está en el techo y el 1,29 % en el piso. No se usa como variable objetivo ni se reporta su media sin aclararlo.
- Las marginales de tráfico, clima y comportamiento del conductor tienen forma de U (curtosis ≈ −1,5): es la distribución del dataset de Kaggle del que se calibran.
- Los datos reales cubren 2016-09 a 2018-08, con un régimen irregular de demoras (ver `informe_etapa2.md`).
