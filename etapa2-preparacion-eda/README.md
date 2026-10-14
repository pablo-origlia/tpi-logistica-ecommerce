# Etapa 2 — Preparación y análisis de los datos

*TPI Análisis de Datos Masivos — Maestría en Ciencias de Datos, UCASAL 2026*

Esta etapa diagnostica la calidad de los datos, construye el **dataset analítico** (una fila por orden entregada) a partir de la base operacional, realiza el análisis exploratorio y vuelve a analizar el plan de ejecución. El dataset analítico es el insumo de las Etapas 3 y 4.

---

## 1. Contenido

```
etapa2-preparacion-eda/
├── sql/
│   ├── 01_diagnostico_calidad.sql      52 chequeos de calidad (solo lectura)
│   ├── 02_vistas_analiticas.sql        vistas y vista materializada del dataset analítico
│   ├── 03_tablas_temporales.sql        tablas TEMP con percentiles, límites IQR y resumen por segmento
│   ├── 04_explain_etapa2.sql           plan de ejecución: vista lógica vs materializada
│   ├── 05_refresh_y_mantenimiento.sql  REFRESH CONCURRENTLY y auditoría de índices
│   └── run_pipeline.ps1                ejecuta todo en orden
├── notebooks/
│   ├── 01_limpieza.ipynb               diagnóstico, dataset analítico y exportación
│   └── 02_eda.ipynb                    análisis exploratorio
├── output/
│   ├── dataset_analitico.parquet       dataset analítico (9 MB)
│   ├── dataset_analitico.csv           el mismo dataset en CSV (34 MB)
│   ├── dataset_analitico_muestra1000.csv   muestra reproducible de 1.000 filas
│   ├── diagnostico_calidad.csv         resultado del diagnóstico
│   ├── flota_mes_tipo.csv              flota por mes y tipo de vehículo
│   └── conductores.csv                 perfil por conductor
├── figures/                            siete gráficos del análisis exploratorio
└── docs/
    ├── informe_calidad_datos.md        diagnóstico, decisiones y volumen de datos
    ├── informe_etapa2.md               informe de la etapa
    ├── conclusiones_eda.md             hallazgos y consecuencias para la Etapa 3
    └── diagnostico_calidad.txt · tablas_temporales.txt · explain_etapa2.txt ·
        refresh_y_mantenimiento.txt · resumen_tiempos_etapa2.csv      salidas de los scripts SQL
```

Los campos del dataset analítico (49 variables y 6 flags de outliers) y su rol en el modelado están en la hoja *Dataset analítico* de `../etapa1-datos-arquitectura/docs/diccionario_datos_kpis.xlsx`.

---

## 2. Requisitos

- La Etapa 1 ejecutada: `olist_logistics_db` con las 14 tablas cargadas.
- PowerShell y `psql` en el PATH.
- Python 3.10 o superior con Jupyter y las librerías del análisis:
  ```powershell
  pip install jupyter pandas numpy scipy matplotlib seaborn scikit-learn sqlalchemy psycopg2-binary pyarrow
  ```

---

## 3. Cómo ejecutar

### 3.1 Pipeline completo

```powershell
cd sql
.\run_pipeline.ps1
```

Pide la contraseña de PostgreSQL una sola vez y ejecuta, en este orden:

| Paso (`-Step`) | Qué ejecuta | Qué deja |
|---|---|---|
| `vistas` | `02_vistas_analiticas.sql` | vistas y materializada del dataset |
| `diagnostico` | `01_diagnostico_calidad.sql` | `docs/diagnostico_calidad.txt` |
| `temporales` | `03_tablas_temporales.sql` | `docs/tablas_temporales.txt` |
| `explain` | `04_explain_etapa2.sql` (3 corridas) | `docs/explain_etapa2.txt` y `docs/resumen_tiempos_etapa2.csv` |
| `refresh` | `05_refresh_y_mantenimiento.sql` | `docs/refresh_y_mantenimiento.txt` |
| `notebooks` | `01_limpieza.ipynb` y `02_eda.ipynb` | dataset en `output/` y gráficos en `figures/` |

El pipeline verifica que la Etapa 1 esté cargada, informa cuántos chequeos del diagnóstico tienen hallazgos y si algún chequeo "Debe ser 0" no da cero, y se detiene ante cualquier error. Con `-SinNotebooks` omite la ejecución de los notebooks, y con `-Step <paso>` ejecuta un solo paso.

Para que la medición de performance sea comparable conviene cerrar los programas pesados (Jupyter, navegador): las corridas varían ±20 % por la caché y la carga de la máquina.

### 3.2 Ejecución manual

```powershell
chcp 65001; $env:PGCLIENTENCODING = "UTF8"       # evita los acentos rotos en consola
psql -U postgres -d olist_logistics_db -f 02_vistas_analiticas.sql
psql -U postgres -d olist_logistics_db -f 01_diagnostico_calidad.sql > ..\docs\diagnostico_calidad.txt
$env:PG_URL = "postgresql+psycopg2://postgres:TU_CLAVE@localhost:5432/olist_logistics_db"
jupyter lab                                        # ejecutar 01_limpieza y luego 02_eda
```

Siempre con `-f archivo.sql` (no con `$(cat ...)`), por la codificación de la consola de Windows.

---

## 4. Decisiones de preparación

- **Grano: una fila por orden entregada.** Las tablas de ítems, pagos y reseñas son relaciones 1 a N; unirlas sin agregar multiplicaría las filas e inflaría los indicadores.
- **Selección:** órdenes `delivered` con fechas consistentes, con registro en la flota y con ítems. El dataset conserva el 96,8 % de las órdenes.
- **Peso:** 0, nulo o producto auxiliar se imputan con la mediana de la categoría, con un indicador (`flag_peso_imputado`).
- **Geografía:** un centroide (mediana) por código postal, dentro del bounding box de Brasil; con él se calcula la distancia haversine.
- **Una sola definición de demora:** `demora_olist` (entrega posterior a la fecha prometida). `delivery_status` de la flota la replica.
- **Outliers:** se marcan con la regla de Tukey y no se eliminan. No se marcan las variables acotadas ni las simuladas de rango fijo.
- **Vista materializada ordenada** por mes y estado, con índice único para poder refrescarla sin bloquear las lecturas.

El detalle y las cifras están en `docs/informe_calidad_datos.md`.

---

## 5. Resultados

| | |
|---|---|
| Diagnóstico | 52 chequeos, 29 con hallazgos; todos los controles "Debe ser 0" dan 0 |
| Dataset analítico | 96.281 órdenes × 49 variables |
| Consulta filtrada (SP, un mes) | 879 ms en la vista lógica y 5,6 ms en la materializada (≈ 160 veces) |
| Refresco de la materializada | ≈ 8 s; `CONCURRENTLY` no bloquea las lecturas |
| Hallazgo principal | La demora real reduce la reseña de 4,29 a 2,56 y se concentra en BA (14,0 %) y RJ (13,5 %) |

Las conclusiones del análisis exploratorio están en `docs/conclusiones_eda.md`, y el informe de la etapa en `docs/informe_etapa2.md`.

---

## 6. Errores frecuentes

| Error | Causa | Solución |
|---|---|---|
| El pipeline dice que no hay datos de la Etapa 1 | La base está vacía o es otra | Ejecutar `etapa1-datos-arquitectura\sql\run_pipeline.ps1` |
| `No existe mv_dataset_analitico` | Se ejecutó un paso antes de crear las vistas | `.\run_pipeline.ps1 -Step vistas` |
| El notebook falla al conectar | `PG_URL` no definida o con la clave incorrecta | Usar el pipeline (la arma sola) o definir `PG_URL` |
| `No se encontro 'jupyter'` | Jupyter no instalado | `pip install jupyter` y las librerías del apartado 2 |
| Acentos rotos en consola o en los `.txt` | Codificación de la consola | `chcp 65001; $env:PGCLIENTENCODING = "UTF8"` (el pipeline ya lo hace) |
