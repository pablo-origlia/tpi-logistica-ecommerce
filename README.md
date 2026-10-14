# TPI — Optimización de la cadena logística de última milla

**Asignatura:** Análisis de Datos Masivos · **Maestría en Ciencias de Datos — UCASAL 2026**

**Problema:** análisis del impacto de las condiciones operativas de la flota (tipo de vehículo, conductor, incidentes, tráfico, clima, mantenimiento) sobre los tiempos de entrega y la satisfacción del cliente en un operador de e-commerce brasileño.

El proyecto recorre el proceso completo **BBDD → Consultas → Preparación → Análisis → Indicadores → Visualización → Interpretación → Decisión** en cuatro etapas. Cada etapa tiene su propia carpeta con un `README.md` que detalla qué contiene, cómo ejecutarla y qué produce.

---

## 1. Fuentes de datos

| Fuente | Origen | Rol |
|---|---|---|
| **Olist Brazilian E-Commerce** | [Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) | Datos **reales**: ~100.000 órdenes, 9 tablas, 2016–2018 |
| **Logistics and supply chain dataset** | [Kaggle](https://www.kaggle.com/datasets/datasetengineer/logistics-and-supply-chain-dataset) | Fuente de las distribuciones marginales de las variables simuladas de flota |
| **Flota sintética** | Generada con `generate_fleet_dataset.py` | 5 tablas de flota vinculadas a Olist por `order_id` |

**Clave de vinculación entre fuentes:** `olist_orders.order_id ←→ fleet_deliveries.order_id`

> **Datos reales y simulados.** Las variables de Olist (fechas, reseñas, fletes, estados) son reales. En la flota, `distance_km`, `delivery_status` y `eta_variation_hours` se derivan de datos reales de Olist; tráfico, clima, riesgo de ruta, conductor, incidentes y mantenimiento se simulan condicionados a señales reales. Las asociaciones entre las variables simuladas y la demora real están impuestas por el generador: describen un escenario, no evidencia empírica. Toda conclusión se interpreta con esta salvedad (detalle en `etapa1-datos-arquitectura/docs/propuesta_datasets_tpi.md`).

---

## 2. Estructura del proyecto

```
tpi-logistica-ecommerce/
│
├── README.md                              ← este documento
├── New-TpiStructure.ps1                   ← crea la estructura de carpetas
├── LICENSE
├── .gitignore
│
├── etapa1-datos-arquitectura/             ← problema, datos, base de datos y primeras consultas
│   ├── README.md
│   ├── raw/                               ← CSV originales de Kaggle (10 archivos, no se versionan)
│   ├── fleet_synthetic/                   ← 5 CSV de flota y fleet_generation_log.txt
│   ├── scripts/
│   │   └── generate_fleet_dataset.py      ← genera la flota sintética
│   ├── sql/
│   │   ├── 01_ddl_olist.sql               ← 9 tablas de Olist
│   │   ├── 02_ddl_fleet.sql               ← 5 tablas de flota
│   │   ├── 03_import_data.sql             ← carga de los CSV y auditoría de volúmenes
│   │   ├── 03c_post_import.sql            ← diagnóstico de calidad posterior a la carga
│   │   ├── 03d_sanidad_flota.sql          ← chequeos de sensatez de la flota
│   │   ├── 04_q1_explain.sql … 04_q5_explain.sql   ← las 5 consultas analíticas con EXPLAIN ANALYZE
│   │   ├── 05_indices.sql                 ← 14 índices adicionales
│   │   └── run_pipeline.ps1               ← ejecuta todo en orden y mide el tiempo de cada consulta
│   ├── docs/
│   │   ├── propuesta_datasets_tpi.md      ← problema, fuentes, estructura, preguntas y KPIs
│   │   └── diccionario_datos_kpis.xlsx    ← tablas, dataset analítico, relaciones, KPIs y performance
│   └── performance/
│       ├── explain_sin_indices/           ← q1_sin_idx.txt … q5_sin_idx.txt
│       ├── explain_con_indices/           ← q1_con_idx.txt … q5_con_idx.txt
│       ├── resumen_tiempos.csv            ← primera ejecución y mediana de cada consulta
│       └── logs/                          ← un log por paso del pipeline
│
├── etapa2-preparacion-eda/                ← calidad de datos, dataset analítico y EDA
│   ├── README.md
│   ├── sql/
│   │   ├── 01_diagnostico_calidad.sql     ← 52 chequeos (solo lectura)
│   │   ├── 02_vistas_analiticas.sql       ← vistas y vista materializada del dataset analítico
│   │   ├── 03_tablas_temporales.sql       ← tablas TEMP para el EDA
│   │   ├── 04_explain_etapa2.sql          ← plan de ejecución: vista lógica vs materializada
│   │   ├── 05_refresh_y_mantenimiento.sql ← REFRESH CONCURRENTLY y auditoría de índices
│   │   └── run_pipeline.ps1               ← ejecuta los SQL y los notebooks en orden
│   ├── notebooks/
│   │   ├── 01_limpieza.ipynb              ← diagnóstico, dataset analítico, exportación
│   │   └── 02_eda.ipynb                   ← análisis exploratorio
│   ├── output/                            ← dataset_analitico (.parquet y .csv), muestra de 1.000 filas y tablas auxiliares
│   ├── figures/                           ← 7 gráficos del EDA
│   └── docs/
│       ├── informe_calidad_datos.md       ← diagnóstico, decisiones y volumen de datos
│       ├── informe_etapa2.md              ← informe de la etapa
│       ├── conclusiones_eda.md            ← hallazgos y consecuencias para la Etapa 3
│       ├── diagnostico_calidad.txt        ← salida de 01_diagnostico_calidad.sql
│       ├── tablas_temporales.txt          ← salida de 03_tablas_temporales.sql
│       ├── explain_etapa2.txt             ← salida de 04_explain_etapa2.sql
│       ├── refresh_y_mantenimiento.txt    ← salida de 05_refresh_y_mantenimiento.sql
│       └── resumen_tiempos_etapa2.csv     ← mediana y mínimo de cada escenario de performance
│
├── etapa3-modelos-bi/                     ← modelos predictivos, KPIs y análisis prescriptivo
│   ├── README.md
│   ├── notebooks/
│   │   ├── 01_modelo_regresion_entrega.ipynb      ← Modelo 1: días de entrega
│   │   └── 02_modelo_clasificacion_demora.ipynb   ← Modelo 2: demora respecto de lo prometido
│   ├── models/                            ← modelos serializados (.pkl)
│   ├── sql/
│   │   └── kpis.sql                       ← una consulta por KPI
│   ├── output/
│   │   └── metricas_modelos.md            ← métricas de evaluación (y predicciones)
│   ├── figures/
│   └── docs/
│       └── informe_modelos.md
│
├── etapa4-dashboard/                      ← producto final
│   ├── README.md
│   ├── pbix/                              ← dashboard (.pbix, .twb o .xlsx)
│   ├── data_source/                       ← copia estable del dataset analítico para el dashboard
│   └── screenshots/                       ← vista ejecutiva, analítica y de decisión
│
└── entregable-final/                      ← copia consolidada para el Drive (ver sección 5)
    ├── README.md
    └── 04_analisis_y_modelos/
```

---

## 3. Cobertura del enunciado

| Etapa | Requisito del enunciado | Dónde está |
|---|---|---|
| **1** | Problema, contexto y usuarios | `etapa1-datos-arquitectura/docs/propuesta_datasets_tpi.md` |
| | 3 a 5 preguntas analíticas | `propuesta_datasets_tpi.md` (Q1–Q5) |
| | Estructura de la BBDD (tablas, claves, relaciones) | `docs/diccionario_datos_kpis.xlsx` (hojas Diccionario y Relaciones), `sql/01_ddl_olist.sql`, `sql/02_ddl_fleet.sql` |
| | Caracterización de los datos (estructurados, semiestructurados, no estructurados) y su origen | `propuesta_datasets_tpi.md` (fuentes y caracterización) |
| | Consultas SQL con tiempo, registros, memoria, I/O, plan estimado vs real e impacto | `sql/04_q*_explain.sql`, `performance/`, `diccionario_datos_kpis.xlsx` (hoja Performance) |
| **2** | Diagnóstico de calidad (nulos, duplicados, inconsistencias, extremos, integridad, categóricas, fechas) | `etapa2-preparacion-eda/sql/01_diagnostico_calidad.sql`, `docs/informe_calidad_datos.md` |
| | Vistas y tablas temporales; dataset analítico | `sql/02_vistas_analiticas.sql`, `sql/03_tablas_temporales.sql`, `output/dataset_analitico.*` |
| | Análisis exploratorio descriptivo | `notebooks/02_eda.ipynb`, `figures/`, `docs/conclusiones_eda.md` |
| | Nuevo análisis del plan de ejecución | `sql/04_explain_etapa2.sql`, `sql/05_refresh_y_mantenimiento.sql` |
| **3** | Técnicas predictivas y prescriptivas justificadas y evaluadas | `etapa3-modelos-bi/notebooks/`, `docs/informe_modelos.md` |
| | Mínimo de 10 KPIs definidos | `etapa1-datos-arquitectura/docs/diccionario_datos_kpis.xlsx` (hoja KPIs), `etapa3-modelos-bi/sql/kpis.sql` |
| **4** | Dashboard con vista ejecutiva, analítica (interactiva) y de decisión | `etapa4-dashboard/pbix/`, `screenshots/` |
| **Final** | Entregable de 7 puntos | `entregable-final/` (sección 5) |

---

## 4. Cómo reproducir el proyecto

```powershell
# 0. Estructura y codificación de la consola
.\New-TpiStructure.ps1
chcp 65001; $env:PGCLIENTENCODING = "UTF8"

# 1. Datos: descargar los CSV de Kaggle en etapa1-datos-arquitectura\raw\ y generar la flota
cd etapa1-datos-arquitectura\scripts
python generate_fleet_dataset.py --input ..\raw --output ..\fleet_synthetic

# 2. Etapa 1: base de datos, carga, validaciones y análisis de performance
psql -U postgres -c "CREATE DATABASE olist_logistics_db;"
cd ..\sql
.\run_pipeline.ps1

# 3. Etapa 2: dataset analítico, diagnóstico, performance y notebooks
cd ..\..\etapa2-preparacion-eda\sql
.\run_pipeline.ps1
```

Cada etapa tiene en su `README.md` el detalle de los pasos, los requisitos y los errores frecuentes.


---

## 5. Entregable final

`entregable-final/` contiene una **copia consolidada** de los mejores productos de cada etapa; no se genera nada nuevo en esa carpeta. Está numerada según los 7 puntos del enunciado:

| # | Punto del enunciado | Archivo o carpeta |
|---|---|---|
| 1 | Base de datos o dataset (parcial top 1000) | `01_dataset_analitico_top1000.csv` |
| 2 | Script SQL de consultas, transformación y generación de información | `02_script_sql_completo.sql` (todos los scripts SQL, en orden de ejecución y comentados) |
| 3 | Dataset analítico final | `03_dataset_analitico.parquet` |
| 4 | Análisis y modelos, con código | `04_analisis_y_modelos/` (notebooks de las etapas 2 y 3, modelos serializados y `generate_fleet_dataset.py`) |
| 5 | Dashboard integral funcional | `05_dashboard_logistica_ecommerce.pbix` |
| 6 | Informe de máximo 5 páginas | `06_informe_final.pdf` |
| 7 | Diccionario de datos y KPIs | `07_diccionario_datos_kpis.xlsx` |

---

## 6. Entornos y convenciones

| Herramienta | Uso | Versión |
|---|---|---|
| PostgreSQL | SGBD principal | 15 o superior (probado en 18) |
| Python | Generación de datos, EDA y modelos | 3.10 o superior |
| pandas, numpy, scipy, scikit-learn, matplotlib, seaborn, sqlalchemy, psycopg2-binary, pyarrow | Análisis y modelos | últimas estables |
| Jupyter Lab | Notebooks | — |
| Power BI Desktop | Dashboard | última estable |

- Los scripts SQL llevan prefijo numérico con el orden de ejecución dentro de su carpeta; los notebooks también.
- Los CSV de `raw/` son la fuente original: nunca se editan y no se versionan (se descargan de Kaggle).
- Las figuras se nombran con un número de orden y la variable principal (por ejemplo `03_correlaciones.png`).
- El dataset analítico se produce siempre ejecutando los notebooks en orden; no se regenera a mano.
- El dashboard se conecta a una copia estable del dataset (`etapa4-dashboard/data_source/`), separada de `etapa2-preparacion-eda/output/`.

---

## 7. Licencias y atribución

- **Código** (scripts SQL, Python y PowerShell, y notebooks): GNU General Public License v3.0 (archivo `LICENSE`).
- **Datos de Olist** y los datos derivados de ellos que contiene este repositorio (flota sintética y dataset analítico): el dataset original se publica en Kaggle bajo CC BY-NC-SA 4.0, por lo que su uso es académico y no comercial, con atribución y con la misma licencia para las obras derivadas. Atribución: *Olist, Brazilian E-Commerce Public Dataset by Olist, Kaggle*, https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce.
- **Logistics and Supply Chain Dataset** (Kaggle): aporta solo distribuciones estadísticas para las variables simuladas; su licencia se consulta en la página del dataset.

---

## 8. Estado de las etapas

| Etapa | Estado |
|---|---|
| 1 — Problema, datos y arquitectura | Completa |
| 2 — Preparación y análisis de los datos | Completa |
| 3 — Análisis inteligente y BI | En curso |
| 4 — Dashboard | Pendiente |
