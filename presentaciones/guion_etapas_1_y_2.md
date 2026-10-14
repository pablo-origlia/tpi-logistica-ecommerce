# Guión de la presentación — Etapas 1 y 2

**TPI Análisis de Datos Masivos · Maestría en Ciencias de Datos, UCASAL 2026**
**Proyecto:** optimización de la cadena logística de última milla (Olist y flota sintética)

Este guión cuenta el proceso completo desde el punto de vista del enunciado: qué se pidió, qué se hizo, qué decisiones de diseño se tomaron, qué se encontró en el camino y cómo se mejoró. Está organizado como una secuencia de diapositivas con su mensaje clave, los puntos para decir, el visual sugerido y el tiempo. Puede usarse tal cual como base de la presentación, o recortarse según el tiempo disponible.

> **Duración sugerida:** 20 a 25 minutos más preguntas. Las diapositivas marcadas con ★ son las imprescindibles si hay que recortar a 12 minutos.

---

## 0. El hilo conductor en una frase

> *"Un análisis de datos solo vale si es coherente de punta a punta: del problema a los datos, de los datos a las consultas, de las consultas a los indicadores y de los indicadores a la decisión. Construimos ese recorrido y, en el camino, descubrimos que parte de nuestros datos no servía, lo rehicimos y aprendimos a distinguir qué conclusiones son empíricas y cuáles son propiedades de un simulador."*

**Tres ideas para que el público se lleve:**

1. El problema real es la **demora respecto de lo prometido**: destruye la satisfacción (reseña 2,56 contra 4,29) y se concentra por **destino** (BA y RJ) y por **volumen**.
2. Gran parte del trabajo fue **verificar y corregir**: la flota sintética original no era usable, los índices no mejoraban lo que creíamos, y varias cifras se corrigieron al medirlas bien.
3. Hay una frontera honesta entre lo **real** (Olist) y lo **simulado** (flota). Todo el proyecto la respeta y la declara.

---

## 1. Qué pide el enunciado y cómo lo cubrimos

| Etapa del enunciado | Qué se pide | Dónde lo cubrimos |
|---|---|---|
| **1. Problema, datos y arquitectura** | Problema y contexto; 3–5 preguntas analíticas; estructura de la BBDD; caracterización de los datos; primeras consultas con tiempo, registros, CPU/memoria, E/S, plan, impacto en otras operaciones | Propuesta, diccionario, 14 tablas en PostgreSQL, 5 consultas con `EXPLAIN ANALYZE` sin y con índices |
| **2. Preparación y análisis** | Diagnóstico de calidad; vistas y tablas temporales; dataset analítico; análisis exploratorio; nuevo análisis del plan de ejecución | 52 chequeos, vistas lógica y materializada, tablas `TEMP`, dataset de 96.281 órdenes, EDA, comparación de planes |
| **3. Análisis inteligente y BI** | Técnicas predictivas/prescriptivas justificadas y evaluadas; mínimo 10 KPIs | *Próxima etapa:* 2 modelos, 16 KPIs ya definidos |
| **4. Dashboard** | Vistas ejecutiva, analítica (interactiva) y de decisión | *Etapa final* |
| **Entregable final** | 7 puntos (dataset top 1000, SQL, dataset analítico, modelos, dashboard, informe de 5 páginas, diccionario de datos y KPIs) | Carpeta `entregable-final/` numerada igual que el enunciado |
| **Evaluación** | **Coherencia integral**; evaluación formativa y entre pares | Una sola fuente de verdad por tema y verificaciones automáticas |

---

## 2. Secuencia de diapositivas

### Diapositiva 1 ★ — Título y objetivo (1 min)
- Proyecto, integrantes, asignatura.
- **Mensaje:** vamos a mostrar dos etapas completas y verificadas, y el plan de las dos que siguen.

### Diapositiva 2 ★ — El problema y para quién (2 min)
- **Problema:** impacto de las condiciones operativas de la flota (vehículo, conductor, incidentes, tráfico, clima, mantenimiento) sobre los tiempos de entrega y la satisfacción del cliente en un e-commerce brasileño.
- **Usuarios y decisiones:**
  - Gerencia de operaciones: dónde reforzar capacidad y qué plazos prometer.
  - Jefatura de flota: plan de mantenimiento y asignación de vehículos.
  - Calidad y atención al cliente: anticipar las entregas que dañan la satisfacción.
- **Por qué importa:** la última milla concentra costo y define la experiencia de compra.
- **Visual:** esquema de la cadena (centro de distribución → vehículo → cliente) con los tres usuarios.

### Diapositiva 3 ★ — Las fuentes y la frontera real/simulado (2 min)
- **Olist (real):** ~1,55 millones de filas, 9 tablas, 2016–2018.
- **Dataset de logística de Kaggle:** solo aporta las distribuciones de las variables simuladas.
- **Flota sintética:** 5 tablas, ~101.000 filas, vinculadas a Olist por `order_id`.
- **La frontera:** qué es real, qué se deriva de datos reales y qué es simulado.

| Naturaleza | Variables |
|---|---|
| Real | Fechas, estados, pesos, precios, fletes, reseñas, pagos, coordenadas |
| Derivada de datos reales | `delivery_status`, `distance_km`, `eta_variation_hours` |
| Simulada (condicionada a la realidad) | Tráfico, clima, riesgo, conductor, mantenimiento, incidentes |

- **Mensaje:** esta tabla organiza todas las conclusiones posteriores.

### Diapositiva 4 — Caracterización de los datos (1 min)
- **Estructurados:** las 14 tablas relacionales.
- **No estructurados:** el texto libre de las reseñas (40.977 de 99.224 tienen comentario).
- **Semiestructurados:** no hay.
- **Mensaje:** el enunciado pide caracterizar el tipo de dato; lo hicimos explícitamente y decidimos no analizar el texto en esta fase.

### Diapositiva 5 ★ — Las preguntas analíticas (1 min)
| Q | Pregunta |
|---|---|
| Q1 | ¿Qué factores operativos se asocian a la demora, por estado y tipo de vehículo? |
| Q2 | ¿Hay relación entre el comportamiento del conductor y la satisfacción? |
| Q3 | ¿Los mantenimientos correctivos se concentran en los meses de más demora? |
| Q4 | ¿Qué incidentes tienen más impacto y qué demoras cubren? |
| Q5 | ¿Cómo se relaciona el costo de mantenimiento con el rendimiento por tipo de vehículo? |

### Diapositiva 6 ★ — Arquitectura de la base de datos (2 min)
- **14 tablas en PostgreSQL** (9 de Olist y 5 de flota), 41 índices en el DDL.
- **Relaciones:** `fleet_deliveries` se vincula 1:1 con `olist_orders` por `order_id`; un conductor por vehículo activo; los incidentes apuntan a la orden.
- **Decisiones de diseño del esquema** (se detallan en la sección 3):
  - Sin restricción de rango geográfico (el CSV trae 42 coordenadas fuera de Brasil).
  - Peso del producto ≥ 0 o nulo (hay pesos 0 en el CSV).
  - Clave interna `review_pk`, porque `review_id` tiene 814 duplicados.
  - Producto auxiliar `unknown_product_placeholder` para proteger la integridad referencial.
- **Visual:** diagrama entidad-relación de la propuesta.

### Diapositiva 7 — Carga y validación de la Etapa 1 (1 min)
- Carga con `\copy` (del lado del cliente): funciona en cualquier carpeta, sin permisos especiales del servidor.
- Auditoría automática: 14 conteos, 5 secuencias, integridad referencial y rangos.
- Diagnóstico posterior a la carga: 42 coordenadas inválidas, 4 productos con peso 0, 814 `review_id` duplicados, 8 órdenes `delivered` sin flota.
- **Anécdota útil:** el primer intento falló con *Permission denied*. El servicio de PostgreSQL no puede leer el Escritorio del usuario. Lo resolvimos cambiando a `\copy` y haciendo que el pipeline se detenga ante errores.

### Diapositiva 8 ★ — Análisis de performance de la Etapa 1 (3 min)
- Cinco consultas medidas con `EXPLAIN (ANALYZE, BUFFERS)`, **sin y con 14 índices adicionales**.
- **Cobertura de lo que pide el enunciado:** tiempo; filas procesadas y devueltas (por ejemplo Q1 lee 96.470 entregas para devolver 80 filas); memoria (Q3 hace *spill* a disco, 786 bloques); E/S (buffers); plan estimado frente a real (el planner estima 27 grupos en Q1 y hay 80); impacto sobre otras operaciones.
- **Resultado central:** los planes son **idénticos** sin y con índices y leen los mismos buffers. Solo Q4 usa un índice (`idx_del_status`), y ya venía del DDL.

| Q | Plan | Índice usado | Buffers sin / con |
|---|---|---|---|
| Q1 | Parallel Hash Join (5 tablas) | ninguno | 5.227 / 5.227 |
| Q3 | Hash con *spill* a disco | ninguno | 3.713 / 3.713 |
| Q4 | Bitmap Heap Scan | `idx_del_status` | 1.927 / 1.927 |

- **Por qué:** casi todas las consultas necesitan la mayor parte de las filas (el 97 % de las órdenes está entregado) y las tablas son chicas: un recorrido completo es más barato que los accesos por índice.
- **Lección:** *un índice vale lo que cuesta si lo usa una consulta real.*

### Diapositiva 9 ★ — Etapa 2: la sorpresa (2 min)
- Al diagnosticar la calidad nos encontramos con que **la flota sintética original no servía**.
- **Qué falló:**

| Chequeo | Resultado con la flota original |
|---|---|
| Acuerdo entre `delivery_status` y la demora real | Solo el esperable por azar (kappa = 0,006) |
| Tráfico, clima, riesgo, conductor vs demora | |rho| < 0,03: independientes de la realidad |
| Conductor distinto del vehículo de la entrega | 98,3 % de las entregas |
| Licencia que no habilita el vehículo | 63,5 % |
| Entregas con vehículos dados de baja | 9,3 % |
| `distance_km` | Sin relación con la geografía real |

- **Mensaje:** el diagnóstico de calidad no es un trámite; evitó construir modelos y un dashboard sobre datos incoherentes.

### Diapositiva 10 ★ — La decisión: rehacer la flota (3 min)
- **Idea central:** derivar de datos reales todo lo que se pueda y simular el resto, pero **condicionado a señales reales**.
- **Qué se deriva de datos reales:**
  - `distance_km`: distancia haversine entre vendedor y cliente por un factor de ruta.
  - `delivery_status`: `delayed` si la entrega superó la fecha prometida.
  - `eta_variation_hours`: horas reales de tránsito menos las esperadas.
- **Qué se simula:** tráfico, clima, riesgo, conductor, incidentes y mantenimiento, con una **cópula gaussiana**. Cada variable se construye a partir de señales reales (demora, carga mensual, destino, estación, distancia) más ruido, y se mapea por cuantiles a la distribución de Kaggle: las marginales no cambian, solo la dependencia.
- **Estructura coherente:** un conductor por vehículo activo, licencia habilitante, bajas sin entregas. El mantenimiento se genera después de las entregas, a partir de los kilómetros realmente acumulados.
- **Reproducible:** `SEED = 42`; dos corridas desde cero dieron exactamente los mismos resultados de validación.

### Diapositiva 11 — Cómo se afinó el simulador (2 min)
El generador pasó por tres iteraciones guiadas por validaciones numéricas:

| Versión | Qué se observó | Qué se cambió |
|---|---|---|
| Primera con modelo acoplado | 1.134 mantenimientos, con una proporción de correctivos estimada en ≈ 60 % (irreal) | Probabilidad mensual de correctivo de 0,10 a 0,04 (tope de 0,50 a 0,20) |
| Segunda | 802 mantenimientos, 31,8 % correctivos | — |
| Tercera | Tráfico +0,41 (demasiado visible), riesgo +0,04, conductor −0,58 | Efectos moderados: tráfico 0,25, riesgo 0,30 y sesgo del conductor 0,4 |

- **Resultado final:** tráfico +0,33, clima +0,25, riesgo +0,17 contra la demora real; conductor −0,43; coherencia estructural 100 %.
- **Decisión:** el AUC univariado de tráfico y clima quedó en 0,79. Elegimos **no reajustar** y declarar que estas relaciones son propiedades del simulador (ver diapositiva 18).

### Diapositiva 12 ★ — Diagnóstico y dataset analítico (2 min)
- **52 chequeos, 29 con hallazgos;** todos los controles de coherencia dan cero.
- **Grano del dataset: una fila por orden entregada.** Ítems, pagos y reseñas son relaciones 1 a N: unirlos sin agregar inflaría filas e indicadores (el 9,9 % de las órdenes tiene más de un ítem).
- **Embudo de filas:**

| Paso | Filas |
|---|---:|
| Órdenes totales | 99.441 |
| Entregadas (`delivered`) | 96.478 |
| Con fechas de entrega y despacho | 96.469 |
| Con fechas consistentes | 96.281 |
| **Dataset final** | **96.281 (96,8 %)** |

- **49 variables;** 6 *flags* de outliers (Tukey) solo para variables sin cota.
- **Visual:** embudo de filas.

### Diapositiva 13 ★ — Hallazgo 1: la demora real destruye la satisfacción (1,5 min)
- El 8,1 % de las entregas llega tarde.
- Reseña promedio: **2,56 si llega tarde y 4,29 si llega a tiempo** (d de Cohen = −1,21: efecto muy grande).
- La relación es un **umbral**: llegar antes de lo prometido no mejora la reseña. Por eso el objetivo del modelo es la demora binaria.
- **Visual:** `05_demora_vs_review.png`.

### Diapositiva 14 ★ — Hallazgo 2: el destino concentra el problema (2 min)
- Demora real: **BA 14,0 % y RJ 13,5 %**, frente a SP 5,9 %, MG 5,6 % y PR 5,0 %.
- SP y RJ explican ≈ 52 % de las órdenes tarde: SP por volumen, **RJ por combinar volumen y tasa altos**.
- Los picos de demora acompañan el volumen mensual (rho = +0,68): nov-2017 (14,3 %), feb-2018 (16,0 %) y mar-2018 (21,4 %).
- **Visual:** tabla por estado y `06_serie_mensual.png`.

### Diapositiva 15 — Hallazgo 3: lo que no es lo que parece (2 min)
- **La distancia no aumenta la demora; la reduce** (rho = −0,18). Olist promete plazos más largos para destinos lejanos.
- **El tipo de vehículo no es causal:** moto 7,4 %, van 8,1 %, truck 8,9 %; se asigna por peso (V de Cramér = 0,019).
- **Los correctivos "acompañan" la demora solo por el volumen:** la correlación mensual de +0,58 se vuelve −0,09 por cada 1.000 entregas.
- **Mensaje:** normalizar por volumen evita conclusiones espurias.

### Diapositiva 16 ★ — Hallazgo 4: lo simulado, mostrado con honestidad (2 min)
- Tráfico, clima y riesgo separan las entregas tarde (AUC univariado 0,79, 0,79 y 0,77), y el conductor se asocia con la demora (−0,43; −0,47 ajustado por estado).
- **Pero esas relaciones están impuestas por el generador:** describen un escenario, no evidencia empírica.
- **Consecuencia metodológica:** en la Etapa 3 se comparan dos conjuntos de predictores:
  - **A:** variables reales conocidas al comprar.
  - **B:** A más las variables simuladas.
  - La mejora de B sobre A se presenta como cota superior del escenario, no como poder predictivo.
- **Visual:** tabla de factores con AUC y `04_factores_vs_demora_real.png`.

### Diapositiva 17 ★ — Etapa 2: nuevo análisis del plan de ejecución (3 min)
- **Pregunta del enunciado:** *"un proceso que demora o ralentiza la BBDD en producción no es eficiente."*
- **Comparamos** la vista lógica (recalcula todo) con una copia materializada, indexada y ordenada por mes y estado.

| Escenario | Mediana (ms) |
|---|---:|
| Vista lógica: agregado por estado | 391 |
| Materializada: mismo agregado | 78 |
| Vista lógica: filtro (SP + mes) | 846 |
| **Materializada: mismo filtro** | **5,4** |
| Construcción completa (lo que paga un refresco) | 4.297 |
| `REFRESH` | 9.652 |

- **≈ 157 veces más rápida** la consulta filtrada. Un dashboard sobre la vista lógica pagaría casi un segundo por interacción.
- **Trade-off:** datos tan frescos como el último refresco, 41 MB de disco y un refresco de unos 8 a 10 s (el `CONCURRENTLY` tardó 8,2 s y no bloquea las lecturas).
- **Los índices de la Etapa 1 sí sirven, en otro contexto:** 5 de los 14 se usan en la vista (`idx_cust_id_state`, `idx_del_analytical_base`, entre otros).
- **Auditoría:** 28 índices nunca se usaron (≈ 71 MB); se conservan hasta cerrar las Etapas 3 y 4 y se depuran al final.

### Diapositiva 18 ★ — Lo que mejoramos en el camino (3 min)
Cinco mejoras importantes, cada una nacida de una verificación:

| Qué encontramos | Qué hicimos |
|---|---|
| La flota original era independiente de la realidad | La rehicimos con derivación de datos reales y cópula condicionada |
| Se atribuían mejoras de hasta ~35 % a los índices | Descubrimos que eran caché; pasamos a medir con **mediana de tres repeticiones** y a comparar **planes y buffers** (determinísticos) |
| El cálculo de `dias_desde_ult_mant` leía 18,5 millones de tuplas | Creamos `idx_mnt_vehicle_date`: 0,28 millones, de 0,012 a 0,002 ms por búsqueda |
| Dos columnas decían lo mismo (`demora_flota` y `demora_olist`) | Dejamos una sola definición de demora y eliminamos la redundancia |
| Flags de outliers sobre variables acotadas (tráfico, ETA) | Solo se marcan variables sin cota; la regla de Tukey no aplica a rangos fijos |

### Diapositiva 19 — Proceso y calidad de ingeniería (2 min)
- **Dos pipelines en PowerShell** (uno por etapa): ejecutan todo en orden, se detienen ante errores, verifican las precondiciones y guardan las salidas.
- **Mediciones comparables:** mediana de varias corridas.
- **Higiene:** los logs ya no incluyen rutas locales; `.gitignore` que excluye los datos de Kaggle; licencias separadas para código y datos.
- **Verificación antes de entregar:** cada script se probó sobre una base de prueba y datos sintéticos, y todo el proyecto se ejecutó desde cero.
- **Documentación coherente:** una sola fuente de verdad por tema; 16 KPIs definidos una vez; diccionario con una hoja del dataset analítico y el rol de cada variable en el modelado (predictor A, predictor B, objetivo, excluir por fuga).

### Diapositiva 20 ★ — Qué viene: Etapa 3 (2 min)
| Componente | Plan |
|---|---|
| **Modelo 1 (regresión)** | Objetivo `dias_entrega_total`. Ridge y Random Forest |
| **Modelo 2 (clasificación)** | Objetivo `demora_olist` (8,1 % de positivos). Regresión logística y árbol de decisión; métricas AUC-PR y recall |
| **Validación** | Temporal: entrenamiento hasta 2018-04, prueba desde 2018-05 |
| **Predictores** | Conjunto A (reales) y conjunto B (A más simuladas) |
| **Fuga de información** | Se excluyen las variables conocidas después de la entrega y los objetivos |
| **KPIs** | 16 indicadores en `kpis.sql`, sobre el dataset analítico |
| **Prescriptivo** | Reglas de priorización de destinos por volumen y tasa de demora |

### Diapositiva 21 ★ — Qué viene: Etapa 4 y entregable final (1,5 min)
- **Dashboard** (Power BI, Tableau o Excel):
  - *Vista ejecutiva:* KPIs y alertas.
  - *Vista analítica:* exploración por destino, período, vehículo y conductor, con filtros y drill-down.
  - *Vista de decisión:* predicciones y recomendaciones.
- **Entregable final** (7 puntos): dataset top 1000, SQL unificado, dataset analítico, modelos con código, dashboard, informe de máximo 5 páginas y diccionario de datos y KPIs.
- **Cierre técnico previsto:** depurar los índices sin uso y ejecutar una última vez los pipelines.

### Diapositiva 22 — Riesgos y decisiones abiertas (1 min)
- **AUC alto por construcción** en el conjunto B: hay que presentarlo con cuidado.
- **Régimen temporal irregular** (picos de nov-2017 y feb–mar 2018): puede afectar la validación temporal.
- **Clase desbalanceada** (8,1 %): exige métricas y balanceo apropiados.
- **Hipótesis de saturación de capacidad:** apoyada en 21 meses, sin probar.
- **Pendiente de medición:** si `work_mem = 64 MB` elimina el *spill* de la construcción del dataset.

### Diapositiva 23 ★ — Cierre (1 min)
- Dos etapas completas, verificadas desde cero y documentadas.
- El problema es real y está localizado: **demora respecto de lo prometido, concentrada por destino y volumen**.
- La frontera real/simulado está declarada y respetada.
- Próximo paso: modelos, KPIs y dashboard.

---

## 3. Decisiones de diseño (tabla de referencia)

| Decisión | Alternativas consideradas | Razón |
|---|---|---|
| **Una fila por orden entregada** | Una fila por ítem o por entrega | Ítems, pagos y reseñas son 1 a N: unirlos sin agregar inflaría filas y KPIs |
| **Flota derivada de datos reales + cópula** | Sorteos independientes (la versión inicial) | La independencia respecto de la realidad volvía inútil cualquier análisis |
| **Conservar el AUC alto del simulador** | Bajar los efectos y regenerar todo | Reproducir todo el pipeline tenía un costo alto; basta declarar la limitación y comparar conjuntos A y B |
| **`demora_olist` como única definición de demora** | Mantener dos columnas idénticas | Evita ambigüedad en modelos y KPIs |
| **Vista materializada ordenada, con índice único** | Solo vista lógica | Reduce 157 veces las consultas filtradas; el índice único permite `REFRESH CONCURRENTLY` |
| **Mantener los índices sin uso hasta el final** | Borrarlos ya | Pueden servir a consultas de las Etapas 3 y 4 que todavía no corrieron |
| **Carga con `\copy`** | `COPY` del servidor | Funciona sin permisos especiales y desde cualquier carpeta |
| **Comparar planes y buffers, no solo milisegundos** | Comparar un tiempo único | Los tiempos varían ±20 % por la caché y la carga; los planes son determinísticos |
| **Predictores en dos conjuntos (A y B)** | Un solo conjunto con todo | Separa el poder predictivo real del efecto impuesto por el simulador |
| **Marcar outliers solo en variables sin cota** | Marcar todas | La regla de Tukey no tiene sentido en variables acotadas |
| **`eta_variation_hours` no es objetivo** | Usarla como objetivo del Modelo 1 | Está censurada en los límites (6,4 %) y deriva de las fechas reales |

---

## 4. Cronología resumida

| Momento | Hito |
|---|---|
| Etapa 1 | Problema, preguntas, esquema de 14 tablas, flota sintética inicial, carga y 5 consultas con su análisis de plan |
| Diagnóstico (Etapa 2) | Se descubre que la flota inicial es independiente de la realidad e incoherente |
| Rediseño | Nuevo generador: derivación de datos reales, cópula, estructura coherente; tres rondas de ajuste |
| Dataset analítico | Vistas, materializada, 52 chequeos, embudo de 96,8 % |
| EDA | Hallazgos reales (demora, destino, volumen) y separación de lo simulado |
| Performance | Comparación vista/materializada; el índice de mantenimiento; auditoría de índices |
| Cierre | Pipelines, documentación coherente, verificación desde cero y revisión de licencias |

---

## 5. Preguntas probables de los pares y respuestas

| Pregunta | Respuesta |
|---|---|
| **¿Por qué usaron datos simulados?** | El enunciado admite bases simuladas con un comportamiento razonable. Acoplamos la flota a Olist para que fuera coherente con los datos reales y declaramos qué es real y qué es simulado. |
| **¿Qué prueba que el tráfico influye en la demora?** | Nada: en el simulador esa relación está impuesta. Lo decimos expresamente y por eso comparamos los conjuntos A y B. |
| **¿Por qué no se usó la distancia para explicar la demora?** | Se usó: en los datos reales la distancia se asocia **negativamente** con la demora, porque Olist promete plazos más largos para destinos lejanos. |
| **¿Los índices no sirvieron?** | Para las cinco consultas de la Etapa 1 no cambiaron ningún plan. En la Etapa 2, cinco de los 14 sí se usan en la vista analítica. Los demás quedan en revisión. |
| **¿Por qué una vista materializada?** | La consulta filtrada pasa de ~0,85 s a ~5 ms; a cambio de un refresco de 8 a 10 s y 41 MB. El dashboard no debe pagar un segundo por clic. |
| **¿Cómo evitan la fuga de información?** | Excluimos todo lo que se conoce después de la entrega (tiempos, reseñas, incidentes) y los objetivos; el diccionario marca el rol de cada variable. |
| **¿Por qué no eliminaron los outliers?** | Son entregas reales (fletes altos en regiones remotas, demoras extremas); se marcan y el análisis decide. |
| **¿Qué pasa con los 8 pedidos entregados sin flota?** | Son un defecto conocido de Olist (órdenes sin fecha de entrega); se excluyen. |
| **¿El resultado es reproducible?** | Sí: `SEED = 42` y dos pipelines. Ejecutamos el proyecto desde cero y obtuvimos las mismas tablas. |
| **¿Qué limitaciones tiene el análisis?** | Variables de flota simuladas; período 2016–2018 con un régimen irregular; hipótesis de saturación no probada; `eta_variation_hours` censurada. |

---

## 6. Cifras clave (para tener a mano)

| Tema | Cifra |
|---|---|
| Base de datos | 14 tablas, ~1,65 millones de filas, 41 índices en el DDL y 14 adicionales |
| Flota | 100 vehículos (95 activos), 95 conductores, 96.470 entregas, 802 mantenimientos (31,8 % correctivos), 3.531 incidentes |
| Calidad | 52 chequeos, 29 con hallazgos; 42 coordenadas inválidas; 814 `review_id` duplicados |
| Dataset analítico | 96.281 órdenes × 49 variables (55 columnas exportadas con los flags) |
| Demora real | 8,1 % (7.822 órdenes); reseña 2,56 frente a 4,29 (d = −1,21) |
| Destinos | BA 14,0 %, RJ 13,5 %, SC 9,8 % frente a SP 5,9 %, MG 5,6 %, PR 5,0 % |
| Tiempo de entrega | Mediana 10,2 días; p95 29,3 días |
| Variables simuladas vs demora | Tráfico +0,33 (AUC 0,79), clima +0,25 (0,79), riesgo +0,17 (0,77) |
| Conductor | −0,43 por conductor; −0,47 ajustado por estado |
| Mantenimiento | Correctivos vs demora: +0,58 en absoluto y −0,09 por 1.000 entregas |
| Performance Etapa 1 | Planes idénticos sin y con índices; tiempos −22 % a +24 % (ruido) |
| Performance Etapa 2 | Consulta filtrada 846 ms → 5,4 ms (≈ 157 veces); refresco 8–10 s |
| Índices | 28 sin uso (≈ 71 MB); 5 de los 14 adicionales se usan |

---

## 7. Material visual disponible

| Archivo | Contenido | Diapositiva |
|---|---|---:|
| `etapa2-preparacion-eda/figures/01_distribuciones_tiempos.png` | Distribución de los tiempos de entrega y la demora | 12–13 |
| `.../02_categoricas.png` | Vehículos, destinos y medios de pago | 12 |
| `.../03_correlaciones.png` | Correlaciones de Spearman | 16 |
| `.../04_factores_vs_demora_real.png` | Factores según la demora real | 16 |
| `.../05_demora_vs_review.png` | Reseña frente a la demora (umbral) | 13 |
| `.../06_serie_mensual.png` | Series mensuales y picos | 14 |
| `.../07_conductor_review.png` | Conductor: score, reseña y razón observada/esperada | 16 |
| `etapa1-datos-arquitectura/docs/propuesta_datasets_tpi.md` | Diagrama de la base y tablas | 6 |

---

## 8. Cómo adaptar el guión

- **12 minutos:** diapositivas 1, 2, 3, 5, 6, 8, 9, 10, 12, 13, 14, 16, 17, 18, 20, 21 y 23 (las marcadas con ★).
- **Foco técnico (cátedra):** ampliar las diapositivas 8, 10, 17 y 18, que muestran el rigor del análisis de planes y de la generación de datos.
- **Foco de negocio (pares y usuarios):** ampliar las diapositivas 2, 13, 14 y 16, y dejar las técnicas como anexo.
- **Evaluación entre pares:** abrir con la diapositiva 3 (qué es real y qué es simulado) y reservar tiempo para la sección 5.
