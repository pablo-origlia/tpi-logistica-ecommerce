# Conclusiones del análisis exploratorio — Etapa 2

*Dataset analítico: 96.281 órdenes entregadas (2016-09 a 2018-08). Fuente: `notebooks/02_eda.ipynb`.*

> **Cómo leer este documento.** Los hallazgos de la sección 1 provienen de datos **reales de Olist** y valen por sí mismos. Los de la sección 2 describen el **sistema simulado**: las variables operativas de la flota (tráfico, clima, riesgo, conductor, incidentes y mantenimiento) se generan condicionadas a la realidad, de modo que sus asociaciones están impuestas por diseño y **no constituyen evidencia empírica**. Sirven para disponer de un escenario coherente para los modelos, los KPIs y el dashboard.

---

## 1. Hallazgos sobre datos reales

| # | Hallazgo | Evidencia | Implicancia |
|---|---|---|---|
| 1 | Los tiempos de entrega tienen cola larga | Mediana 10,2 días; p95 29,3; asimetría 3,8. Olist promete con holgura (demora media de −11,2 días) | Usar mediana y percentiles; considerar la transformación logarítmica |
| 2 | La demora real destruye la satisfacción | Reseña 2,56 (tarde) frente a 4,29 (a tiempo); d de Cohen = **−1,21**; Spearman(días de demora, reseña) = −0,177 | Justifica el problema y el KPI de satisfacción. La relación es un umbral: usar `demora_olist` binaria |
| 3 | La demora real es de 8,1 % | 7.822 de 96.281 órdenes | Clase desbalanceada en el Modelo 2: AUC-PR, recall y balanceo |
| 4 | El **destino** concentra el problema | Demora real: BA 14,0 %, RJ 13,5 %, SC 9,8 %, frente a SP 5,9 %, MG 5,6 % y PR 5,0 % | Segmentación principal del dashboard |
| 5 | SP y RJ explican ≈ 52 % de las órdenes tarde | SP ≈ 2.385 y RJ ≈ 1.665 sobre 7.822 | RJ es el destino prioritario: volumen y tasa altos |
| 6 | La distancia **no** aumenta la demora real; la reduce | rho con los días de demora: haversine −0,179, flete −0,155 | Olist promete plazos más largos para destinos lejanos |
| 7 | El tipo de vehículo no explica la demora | moto 7,4 %, van 8,1 %, truck 8,9 %; V de Cramér = 0,019 (p = 1e-8 solo por el tamaño de la muestra) | El tipo se asigna por el peso: no es causal |
| 8 | El volumen mensual acompaña la demora | Picos en nov-2017 (14,3 %), feb-2018 (16,0 %) y mar-2018 (21,4 %); rho(demora, volumen) = +0,68 (21 meses) | Hipótesis de saturación de capacidad (a validar) |

### Detalle por estado de destino (los ocho de mayor volumen)

| Estado | Órdenes | Demora real | Días de entrega (mediana) | Reseña | Flete mediano (BRL) |
|---|---:|---:|---:|---:|---:|
| BA | 3.252 | 14,0 % | 16,9 | 3,93 | 22,1 |
| RJ | 12.330 | 13,5 % | 12,0 | 3,97 | 18,0 |
| SC | 3.534 | 9,8 % | 13,1 | 4,13 | 18,2 |
| RS | 5.327 | 7,2 % | 13,2 | 4,19 | 18,2 |
| DF | 2.077 | 7,1 % | 11,4 | 4,13 | 18,1 |
| SP | 40.427 | 5,9 % | 7,2 | 4,25 | 13,6 |
| MG | 11.327 | 5,6 % | 10,3 | 4,19 | 18,2 |
| PR | 4.912 | 5,0 % | 10,4 | 4,24 | 17,9 |

### Estacionalidad

La tabla por mes calendario mezcla años: septiembre a diciembre existen solo en 2016 y 2017, y enero a agosto en 2017 y 2018. Marzo (17,2 %) refleja sobre todo marzo de 2018 (21,4 %), no un patrón estacional. Para la estacionalidad real se usa la serie año-mes (`06_serie_mensual.png`). Con 21 meses con volumen suficiente, las correlaciones mensuales son orientativas.

---

## 2. Hallazgos sobre el sistema simulado (por diseño)

| # | Hallazgo | Evidencia | Interpretación |
|---|---|---|---|
| 9 | Tráfico, clima y riesgo separan las entregas tarde | rho con los días de demora: tráfico **+0,327**, clima **+0,252**, riesgo **+0,174**. **AUC univariado: 0,789, 0,788 y 0,773**; d de Cohen 1,10, 1,08 y 0,89 (el tráfico es 3,4 puntos mayor en las entregas tarde, sobre una escala 0–10) | Impuesto por el generador. Cada variable separa mucho por sí sola; combinadas darán un AUC aún mayor |
| 10 | El tiempo de carga y descarga no se asocia | rho = −0,006; AUC 0,514 | Sin vínculo por diseño: sirve de control |
| 11 | Conductor: efecto débil por entrega y claro por conductor | Por entrega: behavior↔demora rho = −0,058 (AUC 0,40). Por conductor (n = 95): −0,43 (p = 1,2e-5); behavior↔reseña +0,25 (p = 0,015). **Ajustado por estado de destino:** behavior −0,47 (p = 1,9e-6); fatiga +0,54 (p = 2e-8) | El score y la fatiga sesgan la asignación de entregas tardías; la reseña lo hereda a través de la demora. El ajuste por estado no debilita el efecto |
| 12 | Perfil de conductor | Bajo (41 conductores, 40.582 entregas): 11,4 % de demora, reseña 4,10 · Medio (19; 20.116): 5,5 %, 4,23 · Alto (35; 35.583): 6,1 %, 4,19 | Medio y alto no se ordenan (5,5 % frente a 6,1 %): con pocos conductores por perfil, pesan el ruido y el estado de operación. El efecto es monótono con el score continuo (hallazgo 11) |
| 13 | Mantenimiento e incidentes mensuales frente a la demora | rho mensual (21 meses), valores absolutos: entregas +0,68, correctivos +0,58, incidentes +0,71, costo +0,66. **Por cada 1.000 entregas: correctivos −0,09, incidentes +0,70** | Los correctivos acompañaban a la demora solo a través del volumen. Los incidentes siguen asociados por construcción: su probabilidad incluye la demora |
| 14 | `eta_variation_hours` está censurada | 6,4 % de las entregas en un límite: 5,1 % en el techo (336) y 1,3 % en el piso (−168); p95 = 336 | No usarla como objetivo ni reportar su media sin aclarar el acotamiento |
| 15 | Las variables simuladas tienen forma de U | Curtosis ≈ −1,5 en tráfico, clima y behavior; p25 y p75 del tráfico: 1,5 y 8,5 | Es la distribución de Kaggle; explica el tamaño de las diferencias de medias del hallazgo 9 |
| 16 | Tráfico, clima y riesgo no dependen del tipo de vehículo | Tráfico 5,00, 4,99 y 4,99 (moto, truck, van); clima 0,495, 0,503 y 0,497; riesgo 6,89, 7,04 y 7,04 | Por diseño. Los días de entrega medianos sí difieren (9,4, 11,1 y 10,2) porque el tipo depende del peso |

### Segmento por tipo de vehículo y perfil de conductor (demora real)

| Tipo | Alto | Medio | Bajo |
|---|---:|---:|---:|
| moto | 4,9 % | 5,6 % | 10,4 % |
| van | 5,7 % | 5,2 % | 12,3 % |
| truck | 7,6 % | 4,4 % | 11,0 % |

---

## 3. Respuestas a las preguntas analíticas

| Pregunta | Respuesta |
|---|---|
| **Q1.** ¿Qué factores operativos se asocian a las entregas demoradas por estado y tipo de vehículo? | Con datos reales, el destino: BA y RJ concentran las mayores tasas, y el tipo de vehículo no es un factor (diferencia despreciable, asignado por peso). Entre las variables simuladas, tráfico, clima y riesgo se asocian a la demora por diseño |
| **Q2.** ¿Existe relación entre el comportamiento del conductor y la satisfacción? | Por conductor, sí (rho = +0,25 con la reseña y −0,43 con la tasa de demora), pero por diseño: el simulador asigna más entregas tardías a los conductores de menor score y la reseña lo hereda a través de la demora |
| **Q3.** ¿Se concentran los mantenimientos correctivos en los meses de mayor demora? | Los picos reales de demora (nov-2017, feb-2018 y mar-2018) acompañan el volumen. Los correctivos correlacionan con la demora (+0,58) solo a través del volumen: por cada 1.000 entregas la correlación es −0,09 |
| **Q4.** ¿Qué incidentes tienen más impacto y qué proporción de las demoras cubren? | Los incidentes cubren el 19,2 % de las entregas tardías y el 2,3 % de las puntuales; su probabilidad depende de la demora, el tráfico, el clima, el riesgo, la edad del vehículo y el mantenimiento |
| **Q5.** ¿Cómo se relaciona el costo de mantenimiento con el rendimiento por tipo de vehículo? | La tasa de entrega a tiempo es prácticamente igual entre tipos (92,6 %, 91,9 % y 91,1 %); el costo responde a los rangos del generador. No hay evidencia de que las motos sean más afectadas por el clima o el tráfico |

---

## 4. Consecuencias para la Etapa 3

- **Clasificación (Modelo 2):** objetivo `demora_olist` (8,1 % de positivos): AUC-PR, recall y balanceo de clases. Se comparan dos conjuntos de predictores:
  - **A:** variables reales conocidas al comprar (estados de origen y destino, distancia haversine, flete, peso, categoría, mes, volumen mensual y días prometidos).
  - **B:** A más las variables simuladas (tráfico, clima, riesgo, conductor y `dias_desde_ult_mant`).
  La mejora de B sobre A es por construcción: se presenta como cota superior del escenario simulado. Como referencia, el AUC univariado de tráfico y clima ya es de 0,79.
- **Regresión (Modelo 1):** objetivo `dias_entrega_total`. No usar `eta_variation_hours` (censurada y derivada de las fechas reales).
- **Fuga de información:** excluir de los predictores `dias_entrega_total`, `dias_transito`, `dias_hasta_despacho`, `dias_demora_olist`, `eta_variation_hours`, `delivery_status` (es el objetivo), `review_score`, `resena_negativa`, `n_incidentes` y `horas_impacto_incidentes`. Tráfico, clima y riesgo se generan condicionados al resultado y no se conocerían al comprar: se declaran covariables simuladas.
- **Nulos:** `dias_desde_ult_mant` (2.120, el 2,2 %) y `distancia_haversine_km` (479, el 0,5 %): imputar con un indicador o usar un modelo que admita nulos.
- **KPIs:** los de flota son válidos como indicadores del sistema simulado; los de satisfacción y de entrega a tiempo se calculan sobre datos reales. En el dashboard, priorizar la **tasa de demora real por estado de destino**.
