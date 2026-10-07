# TPI — Optimización de la cadena logística de ultima milla

**Asignatura:** Analisis de Datos Masivos  
**Maestría en Ciencias de Datos — UCASAL 2026**  
**Problema:** Análisis del impacto de las condiciones operativas de la flota (tipo de vehículo, comportamiento del conductor, incidentes, mantenimiento) sobre los tiempos de entrega y la satisfacción del cliente en un operador de e-commerce brasileño.

---

## Fuentes de datos

| Fuente                                 | Origen                                                                                       | Descripción                                                     |
| -------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| **Olist Brazilian E-Commerce**         | [Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)                        | 100.000 ordenes reales, 9 tablas, periodo 2016–2018             |
| **Logistics and supply chain dataset** | [Kaggle](https://www.kaggle.com/datasets/datasetengineer/logistics-and-supply-chain-dataset) | Dataset de flota — usado como fuente de calibración estadística |
| **Fleet sintetico**                    | Generado con `generate_fleet_dataset.py`                                                     | 5 tablas de flota simuladas, vinculadas a Olist via `order_id`  |

**Clave de vinculación entre fuentes:**
```
olist_orders.order_id  ←→  fleet_deliveries.order_id
```

---

## Estructura de carpetas

```
tpi-logistica-ecommerce/
│
├── etapa1-datos-arquitectura/     ← Semana 1
├── etapa2-preparacion-eda/        ← Semana 2
├── etapa3-modelos-bi/             ← Semana 3
├── etapa4-dashboard/              ← Semana 4
└── entregable-final/              ← Entrega Drive
```

---

## etapa1-datos-arquitectura/

Contiene todo lo necesario para definir el problema, montar la base de datos y realizar las primeras consultas SQL con análisis de performance.

```
etapa1-datos-arquitectura/
│
├── raw/
│   ├── olist_orders_dataset.csv
│   ├── olist_order_items_dataset.csv
│   ├── olist_customers_dataset.csv
│   ├── olist_sellers_dataset.csv
│   ├── olist_products_dataset.csv
│   ├── olist_order_reviews_dataset.csv
│   ├── olist_order_payments_dataset.csv
│   ├── olist_geolocation_dataset.csv
│   ├── product_category_name_translation.csv
│   └── dynamic_supply_chain_logistics_dataset.csv
│
├── fleet_synthetic/
│   ├── fleet_vehicles.csv
│   ├── fleet_drivers.csv
│   ├── fleet_deliveries.csv
│   ├── fleet_maintenance.csv
│   ├── fleet_incidents.csv
│   └── fleet_generation_log.txt
│
├── sql/
│   ├── 01_ddl_olist.sql               ← CREATE TABLE para las 9 tablas de Olist
│   ├── 02_ddl_fleet.sql               ← CREATE TABLE para las 5 tablas de flota
│   ├── 03_import_data.sql             ← COPY / BULK INSERT para cargar los CSVs
│   ├── 04_consultas_analiticas.sql    ← Las 5 consultas de las preguntas analiticas
│   └── 05_indices.sql                 ← CREATE INDEX sobre order_id, vehicle_id, etc.
│
├── scripts/
│   └── generate_fleet_dataset.py      ← Genera los 5 CSVs de flota sintética
│
├── docs/
│   ├── propuesta_datasets_tpi.md      ← Propuesta completa (problema, fuentes, KPIs)
│   └── diccionario_datos_v1.xlsx      ← Tablas, campos, tipos, FK y notas de vinculación
│
└── performance/
    ├── explain_sin_indices/           ← Capturas EXPLAIN ANALYZE antes de crear indices
    └── explain_con_indices/           ← Capturas EXPLAIN ANALYZE después de crear indices
```

### ¿Que va en `raw/`?
Los archivos CSV tal como se descargan de Kaggle, **sin modificar**. Nunca editar estos archivos directamente ya que son la fuente de verdad original.

### ¿Que va en `fleet_synthetic/`?
Los 5 archivos CSV producidos al ejecutar `generate_fleet_dataset.py`. Para regenerarlos:
```bash
cd etapa1-datos-arquitectura/scripts
python generate_fleet_dataset.py
# Los CSV se guardan automaticamente en ../fleet_synthetic/
```
El archivo `fleet_generation_log.txt` documenta las métricas de generación y los criterios de vinculación ficticia con Olist.

### ¿Que va en `sql/`?
Los scripts SQL se numeran para indicar el orden de ejecución. Ejecutar en secuencia:
1. `01_ddl_olist.sql` — crea las tablas de Olist con PKs, FKs y tipos correctos.
2. `02_ddl_fleet.sql` — crea las 5 tablas de flota.
3. `03_import_data.sql` — carga los CSVs usando `COPY` (PostgreSQL) o equivalente.
4. `04_consultas_analiticas.sql` — las 5 consultas de las preguntas analíticas de la Etapa 1.
5. `05_indices.sql` — indices sobre las columnas de JOIN mas frecuentes.

### ¿Que va en `performance/`?
Capturas de texto o imágenes de los planes de ejecución obtenidos con `EXPLAIN ANALYZE` en PostgreSQL (o equivalente en el SGBD elegido). Guardar una version **antes** de crear los indices y otra **después**, para comparar tiempos, filas procesadas y tipo de operación (Seq Scan vs Index Scan).

---

## etapa2-preparacion-eda/

Contiene el proceso de limpieza, transformación y análisis exploratorio de datos. El producto principal de esta etapa es el **dataset analítico**, que es el insumo de las etapas 3 y 4.

```
etapa2-preparacion-eda/
│
├── notebooks/
│   ├── 01_limpieza.ipynb              ← Diagnostico de calidad + transformaciones
│   └── 02_eda.ipynb                   ← Análisis exploratorio (estadísticas, gráficos)
│
├── sql/
│   ├── vistas_analiticas.sql          ← CREATE VIEW para el dataset analítico
│   └── tablas_temporales.sql          ← Tablas temporales (#) para cálculos intermedios
│
├── output/
│   ├── dataset_analitico.csv          ← Dataset analítico final
│   └── dataset_analitico.parquet      ← Misma data en formato Parquet (opcional, mas eficiente)
│
├── docs/
│   └── informe_calidad_datos.md       ← Diagnostico: nulos, duplicados, outliers, decisiones
│
└── figures/
    ├── distribucion_delay.png
    ├── correlaciones_heatmap.png
    ├── boxplot_review_por_vehiculo.png
    └── serie_temporal_ordenes.png
```

### ¿Que va en `notebooks/`?
- `01_limpieza.ipynb`: diagnostico de calidad (nulos, duplicados, tipos de datos, valores extremos en `distance_km` y `eta_variation_hours`, inconsistencias de fechas en Olist) y las transformaciones aplicadas.
- `02_eda.ipynb`: análisis descriptivo sobre el dataset analítico — distribuciones, percentiles, correlaciones, análisis temporal, segmentaciones por tipo de vehículo y region.

### ¿Que va en `output/`?
El **dataset analítico** es la tabla resultante del JOIN principal entre Olist y las tablas de flota, con las variables limpias y las columnas calculadas (ej. `delay_hours`, `days_since_last_maintenance`). Este archivo es la entrada para los modelos de la Etapa 3 y para el dashboard de la Etapa 4. No regenerarlo manualmente — siempre producirlo ejecutando los notebooks en orden.

### ¿Que va en `docs/`?
El informe de calidad documenta cada decision de transformación: que se imputo, que se elimino, por que, y que impacto tiene sobre el volumen de datos disponible para el análisis.

---

## etapa3-modelos-bi/

Contiene los modelos de machine learning, las queries de KPIs y los resultados del análisis inteligente.

```
etapa3-modelos-bi/
│
├── notebooks/
│   ├── 01_modelo_regresion_eta.ipynb      ← Modelo 1: predicción de eta_variation_hours
│   └── 02_modelo_clasificacion_delay.ipynb ← Modelo 2: clasificación on_time / delayed
│
├── models/
│   ├── rf_regressor_eta.pkl               ← Random Forest Regressor serializado
│   └── dt_classifier_delay.pkl            ← Decision Tree Classifier serializado
│
├── sql/
│   └── kpis.sql                           ← Queries para los 14 KPIs definidos
│
├── output/
│   ├── predicciones_eta.csv               ← Predicciones del modelo 1
│   ├── predicciones_delay.csv             ← Predicciones del modelo 2
│   └── metricas_modelos.md                ← RMSE, R², accuracy, F1, matriz de confusion
│
├── docs/
│   └── informe_modelos.md                 ← Justificación de técnicas, variables, resultados
│
└── figures/
    ├── feature_importance_rf.png
    ├── matriz_confusion.png
    ├── curva_roc.png
    └── arbol_decision.png
```

### ¿Que va en `notebooks/`?
- `01_modelo_regresion_eta.ipynb`: predicción de `eta_variation_hours` (variable continua) usando Random Forest Regressor. Variables: `distance_km`, `route_risk_level`, `vehicle_type`, `driver_behavior_score`, `fatigue_score_avg`, mes, estado.
- `02_modelo_clasificacion_delay.ipynb`: clasificación binaria `delivery_status` (on_time / delayed) con Árbol de Decisión o Regresión Logística. Permite comparar dos algoritmos distintos sobre el mismo problema.

### ¿Que va en `models/`?
Los modelos entrenados exportados con `joblib.dump()`. Sirven para invocarlos desde el dashboard o para regenerar predicciones sin reentrenar.

### ¿Que va en `sql/kpis.sql`?
Una query por cada uno de los 14 KPIs definidos en la propuesta, comentadas con nombre, formula y fuente. Estas queries son la base de las visualizaciones del dashboard.

---

## etapa4-dashboard/

Contiene el producto final: el dashboard integral e interactivo conectado al dataset analítico.

```
etapa4-dashboard/
│
├── pbix/
│   └── dashboard_logistica_ecommerce.pbix   ← Archivo Power BI (o .twb para Tableau)
│
├── data_source/
│   └── dataset_analitico_dashboard.csv      ← Copia del dataset analítico para el dashboard
│
└── screenshots/
    ├── vista_ejecutiva.png                  ← KPIs principales y estado general
    ├── vista_analitica.png                  ← Drill-down por region, vehículo, periodo
    └── vista_decision.png                   ← Predicciones, alertas y recomendaciones
```

### ¿Que va en `pbix/`?
El archivo del dashboard. Si el equipo no tiene integrantes con Power BI o Tableau, el enunciado acepta Excel — en ese caso guardar aqui el `.xlsx` con las tablas dinámicas y gráficos.

### ¿Que va en `data_source/`?
Una copia estable del dataset analítico de Etapa 2, específicamente formateada para conectarse al dashboard. Mantenerla separada del `output/` de Etapa 2 evita que una regeneración del dataset rompa las conexiones del dashboard.

### ¿Que va en `screenshots/`?
Las tres vistas obligatorias del enunciado capturadas como imágenes, para incluirlas en el informe final y en la presentación oral.

---

## entregable-final/

Archivos listos para subir al Drive de entrega. Todo lo que va aquí es una **copia consolidada** de los mejores productos de cada etapa — no generar nada nuevo en esta carpeta.

```
entregable-final/
│
├── informe_final.pdf                        ← Max. 5 paginas (problema, metodología, hallazgos)
├── diccionario_kpis.xlsx                    ← Diccionario de datos completo + tabla de KPIs
├── dataset_analitico_top1000.csv            ← Muestra de 1000 filas del dataset analítico
├── script_sql_completo.sql                  ← Todos los scripts SQL unificados y comentados
├── dashboard_logistica_ecommerce.pbix       ← Dashboard funcional
└── generate_fleet_dataset.py                ← Script de generación de flota (con docstring completo)
```

> El enunciado pide explícitamente una muestra `top 1000` del dataset para la entrega en Drive. El dataset analítico completo puede ser demasiado pesado para Drive — la muestra alcanza para demostrar la estructura.

---

## Convenciones del proyecto

### Nomenclatura de archivos
- Scripts SQL numerados con prefijo de orden de ejecucion: `01_`, `02_`, etc.
- Notebooks numerados en orden de ejecución dentro de cada etapa.
- Figuras nombradas con el tipo de gráfico y la variable principal: `distribucion_delay.png`.

### Entornos y herramientas
| Herramienta                 | Uso                           | Version recomendada |
| --------------------------- | ----------------------------- | ------------------- |
| PostgreSQL                  | SGBD principal                | 15+                 |
| Python                      | Generación de datos + modelos | 3.10+               |
| pandas, numpy, scikit-learn | Análisis y modelos            | ultimas estables    |
| Jupyter Notebook / Lab      | Notebooks de análisis         | -                   |
| Power BI Desktop            | Dashboard                     | ultimas estables    |

### Flujo de datos entre etapas
```
raw/ (Olist + Kaggle)
    └─► generate_fleet_dataset.py ──► fleet_synthetic/
            │
            ▼
    PostgreSQL: olist_logistics_db
            │
            ▼
    etapa2: limpieza + EDA ──► dataset_analitico.csv
                                        │
                          ┌─────────────┴─────────────┐
                          ▼                           ▼
               etapa3: modelos ML          etapa4: dashboard
               predicciones + KPIs         (conectado al dataset)
                          │
                          └──────────────► entregable-final/
```

---

## Como empezar (Etapa 1)

```bash
# 1. Descargar los datasets de Kaggle y colocarlos en:
#    etapa1-datos-arquitectura/raw/

# 2. Generar el dataset de flota sintetica
cd etapa1-datos-arquitectura/scripts
python generate_fleet_dataset.py
# Outputs → ../fleet_synthetic/

# 3. Crear la base de datos en PostgreSQL
psql -U postgres -c "CREATE DATABASE olist_logistics_db;"

# 4. Ejecutar los scripts SQL en orden
psql -U postgres -d olist_logistics_db -f ../sql/01_ddl_olist.sql
psql -U postgres -d olist_logistics_db -f ../sql/02_ddl_fleet.sql
psql -U postgres -d olist_logistics_db -f ../sql/03_import_data.sql

# 5. Verificar la carga
psql -U postgres -d olist_logistics_db -c "SELECT COUNT(*) FROM olist_orders;"
psql -U postgres -d olist_logistics_db -c "SELECT COUNT(*) FROM fleet_deliveries;"
```
