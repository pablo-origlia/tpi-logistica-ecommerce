<#
.SYNOPSIS
    Crea la estructura de carpetas y archivos placeholder del TPI.

.DESCRIPTION
    Genera el árbol completo de directorios para el proyecto
    "Optimización de la cadena logística de última milla"
    (Análisis de Datos Masivos — Maestría en Ciencias de Datos, UCASAL 2026).

    Los archivos .gitkeep mantienen las carpetas vacías en Git.
    Los archivos placeholder (.sql, .md, .ipynb) se crean vacíos
    listos para ser completados.

.PARAMETER RootPath
    Ruta donde se creará la carpeta raíz tpi-logistica-ecommerce/.
    Por defecto: directorio actual.

.EXAMPLE
    .\New-TpiStructure.ps1
    .\New-TpiStructure.ps1 -RootPath "C:\Proyectos"

.NOTES
    Requiere PowerShell 5.1 o superior.
#>

param(
    [string]$RootPath = "."
)

# ─────────────────────────────────────────
# CONFIGURACIÓN
# ─────────────────────────────────────────
$ProjectName = "tpi-logistica-ecommerce"
$Root = Join-Path (Resolve-Path $RootPath) $ProjectName

# ─────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────
function New-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function New-Placeholder {
    param([string]$Path, [string]$Content = "")
    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Path $Path -Force | Out-Null
        if ($Content) {
            Set-Content -Path $Path -Value $Content -Encoding UTF8
        }
    }
}

function New-GitKeep {
    param([string]$Dir)
    New-Placeholder -Path (Join-Path $Dir ".gitkeep")
}

# ─────────────────────────────────────────
# INICIO
# ─────────────────────────────────────────
Write-Host ""
Write-Host "  Creando estructura del TPI en:" -ForegroundColor Cyan
Write-Host "  $Root" -ForegroundColor White
Write-Host ""

New-Dir $Root

# ─────────────────────────────────────────
# README en la raíz
# ─────────────────────────────────────────
New-Placeholder -Path "$Root\README.md" -Content "# TPI — Optimización de la cadena logística de última milla`n`nVer README.md completo en la carpeta del proyecto."

# ─────────────────────────────────────────
# ETAPA 1 — Datos y arquitectura
# ─────────────────────────────────────────
$E1 = "$Root\etapa1-datos-arquitectura"

New-Dir "$E1\raw"
New-Placeholder -Path "$E1\raw\.gitkeep" -Content "# Colocar aquí los CSV descargados de Kaggle (Olist + Dynamic Supply Chain)"

New-Dir "$E1\fleet_synthetic"
New-Placeholder -Path "$E1\fleet_synthetic\.gitkeep" -Content "# Generado por: etapa1-datos-arquitectura\scripts\generate_fleet_dataset.py"

New-Dir "$E1\sql"
New-Placeholder -Path "$E1\sql\01_ddl_olist.sql"            -Content "-- DDL: CREATE TABLE para las 9 tablas de Olist (PKs, FKs, tipos de datos)"
New-Placeholder -Path "$E1\sql\02_ddl_fleet.sql"            -Content "-- DDL: CREATE TABLE para las 5 tablas de flota sintética"
New-Placeholder -Path "$E1\sql\03_import_data.sql"          -Content "-- COPY / BULK INSERT para cargar los CSVs en PostgreSQL"
New-Placeholder -Path "$E1\sql\04_consultas_analiticas.sql" -Content "-- 5 consultas analíticas de las preguntas de la Etapa 1"
New-Placeholder -Path "$E1\sql\05_indices.sql"              -Content "-- CREATE INDEX sobre order_id, vehicle_id, seller_state, etc."

New-Dir "$E1\scripts"
New-Placeholder -Path "$E1\scripts\generate_fleet_dataset.py" -Content "# Copiar aquí generate_fleet_dataset.py (v1.1)"

New-Dir "$E1\docs"
New-Placeholder -Path "$E1\docs\propuesta_datasets_tpi.md"  -Content "# Propuesta de datasets — completar con el documento de propuesta"
New-Placeholder -Path "$E1\docs\diccionario_datos_v1.xlsx"  -Content ""

New-Dir "$E1\performance\explain_sin_indices"
New-Dir "$E1\performance\explain_con_indices"
New-GitKeep -Dir "$E1\performance\explain_sin_indices"
New-GitKeep -Dir "$E1\performance\explain_con_indices"

Write-Host "  [OK] etapa1-datos-arquitectura/" -ForegroundColor Green

# ─────────────────────────────────────────
# ETAPA 2 — Preparación y EDA
# ─────────────────────────────────────────
$E2 = "$Root\etapa2-preparacion-eda"

New-Dir "$E2\notebooks"
New-Placeholder -Path "$E2\notebooks\01_limpieza.ipynb"     -Content '{"cells":[],"metadata":{"kernelspec":{"display_name":"Python 3","language":"python","name":"python3"}},"nbformat":4,"nbformat_minor":5}'
New-Placeholder -Path "$E2\notebooks\02_eda.ipynb"          -Content '{"cells":[],"metadata":{"kernelspec":{"display_name":"Python 3","language":"python","name":"python3"}},"nbformat":4,"nbformat_minor":5}'

New-Dir "$E2\sql"
New-Placeholder -Path "$E2\sql\vistas_analiticas.sql"       -Content "-- CREATE VIEW para el dataset analítico (JOIN principal Olist + flota)"
New-Placeholder -Path "$E2\sql\tablas_temporales.sql"       -Content "-- Tablas temporales (#) para cálculos intermedios del EDA"

New-Dir "$E2\output"
New-Placeholder -Path "$E2\output\.gitkeep"                 -Content "# dataset_analitico.csv y .parquet se generan al ejecutar 01_limpieza.ipynb"

New-Dir "$E2\docs"
New-Placeholder -Path "$E2\docs\informe_calidad_datos.md"   -Content "# Informe de calidad de datos`n`n## Diagnóstico inicial`n## Transformaciones aplicadas`n## Impacto en el volumen de datos"

New-Dir "$E2\figures"
New-GitKeep -Dir "$E2\figures"

Write-Host "  [OK] etapa2-preparacion-eda/" -ForegroundColor Green

# ─────────────────────────────────────────
# ETAPA 3 — Modelos y BI
# ─────────────────────────────────────────
$E3 = "$Root\etapa3-modelos-bi"

New-Dir "$E3\notebooks"
New-Placeholder -Path "$E3\notebooks\01_modelo_regresion_eta.ipynb"        -Content '{"cells":[],"metadata":{"kernelspec":{"display_name":"Python 3","language":"python","name":"python3"}},"nbformat":4,"nbformat_minor":5}'
New-Placeholder -Path "$E3\notebooks\02_modelo_clasificacion_delay.ipynb"  -Content '{"cells":[],"metadata":{"kernelspec":{"display_name":"Python 3","language":"python","name":"python3"}},"nbformat":4,"nbformat_minor":5}'

New-Dir "$E3\models"
New-Placeholder -Path "$E3\models\.gitkeep"                 -Content "# rf_regressor_eta.pkl y dt_classifier_delay.pkl se generan al ejecutar los notebooks"

New-Dir "$E3\sql"
New-Placeholder -Path "$E3\sql\kpis.sql"                    -Content "-- Queries para los 14 KPIs definidos en la propuesta"

New-Dir "$E3\output"
New-Placeholder -Path "$E3\output\metricas_modelos.md"      -Content "# Métricas de evaluación`n`n## Modelo 1 — Regresión ETA`n## Modelo 2 — Clasificación delay"

New-Dir "$E3\docs"
New-Placeholder -Path "$E3\docs\informe_modelos.md"         -Content "# Informe de modelos`n`n## Técnica elegida`n## Justificación`n## Variables utilizadas`n## Resultados`n## Evaluación`n## Significado para el problema"

New-Dir "$E3\figures"
New-GitKeep -Dir "$E3\figures"

Write-Host "  [OK] etapa3-modelos-bi/" -ForegroundColor Green

# ─────────────────────────────────────────
# ETAPA 4 — Dashboard
# ─────────────────────────────────────────
$E4 = "$Root\etapa4-dashboard"

New-Dir "$E4\pbix"
New-Placeholder -Path "$E4\pbix\.gitkeep"                   -Content "# dashboard_logistica_ecommerce.pbix (Power BI) o .twb (Tableau)"

New-Dir "$E4\data_source"
New-Placeholder -Path "$E4\data_source\.gitkeep"            -Content "# Copia estable del dataset analítico para conectar al dashboard"

New-Dir "$E4\screenshots"
New-Placeholder -Path "$E4\screenshots\.gitkeep"            -Content "# vista_ejecutiva.png / vista_analitica.png / vista_decision.png"

Write-Host "  [OK] etapa4-dashboard/" -ForegroundColor Green

# ─────────────────────────────────────────
# ENTREGABLE FINAL
# ─────────────────────────────────────────
$EF = "$Root\entregable-final"

New-Dir $EF
New-Placeholder -Path "$EF\.gitkeep"                        -Content "# Copiar aquí los entregables finales para subir al Drive`n# informe_final.pdf | diccionario_kpis.xlsx | dataset_analitico_top1000.csv | script_sql_completo.sql | dashboard .pbix | generate_fleet_dataset.py"

Write-Host "  [OK] entregable-final/" -ForegroundColor Green

# ─────────────────────────────────────────
# RESUMEN
# ─────────────────────────────────────────
Write-Host ""
Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Estructura creada exitosamente." -ForegroundColor Cyan
Write-Host ""

$Dirs  = (Get-ChildItem -Path $Root -Recurse -Directory).Count
$Files = (Get-ChildItem -Path $Root -Recurse -File).Count

Write-Host "  Carpetas : $Dirs" -ForegroundColor White
Write-Host "  Archivos : $Files (placeholders)" -ForegroundColor White
Write-Host ""
Write-Host "  Próximo paso:" -ForegroundColor Yellow
Write-Host "  1. Copiar generate_fleet_dataset.py en etapa1-datos-arquitectura\scripts\" -ForegroundColor White
Write-Host "  2. Copiar propuesta_datasets_tpi.md en etapa1-datos-arquitectura\docs\" -ForegroundColor White
Write-Host "  3. Descargar los CSV de Kaggle en etapa1-datos-arquitectura\raw\" -ForegroundColor White
Write-Host "  4. Ejecutar generate_fleet_dataset.py para generar los CSV de flota" -ForegroundColor White
Write-Host ""
Write-Host "  Ruta del proyecto: $Root" -ForegroundColor DarkGray
Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
