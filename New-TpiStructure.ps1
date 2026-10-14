<#
.SYNOPSIS
    Crea la estructura de carpetas y los archivos placeholder del TPI.

.DESCRIPTION
    Genera el arbol de directorios del proyecto "Optimizacion de la cadena
    logistica de ultima milla" (Analisis de Datos Masivos - Maestria en
    Ciencias de Datos, UCASAL 2026), tal como se describe en README.md.

    El script es idempotente: no sobrescribe archivos existentes, por lo que
    puede ejecutarse sobre un proyecto ya iniciado para completar lo que falte.
    Los archivos se escriben en UTF-8 sin BOM.

.PARAMETER RootPath
    Ruta donde se creara la carpeta raiz tpi-logistica-ecommerce.
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

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------
# CONFIGURACION
# ------------------------------------------------------------------
$ProjectName = "tpi-logistica-ecommerce"
$Root = Join-Path (Resolve-Path $RootPath) $ProjectName

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$EmptyNotebook = '{"cells":[],"metadata":{"kernelspec":{"display_name":"Python 3 (ipykernel)","language":"python","name":"python3"}},"nbformat":4,"nbformat_minor":5}'

$script:Created = 0

# ------------------------------------------------------------------
# FUNCIONES AUXILIARES
# ------------------------------------------------------------------
function New-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function New-Placeholder {
    # Crea el archivo solo si no existe (nunca sobrescribe).
    param([string]$Path, [string]$Content = "")
    if (-not (Test-Path $Path)) {
        New-Dir (Split-Path $Path -Parent)
        [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
        $script:Created++
    }
}

function New-GitKeep {
    param([string]$Dir)
    New-Dir $Dir
    New-Placeholder -Path (Join-Path $Dir ".gitkeep")
}

function Write-Stage {
    param([string]$Name)
    Write-Host "  [OK] $Name" -ForegroundColor Green
}

# ------------------------------------------------------------------
# INICIO
# ------------------------------------------------------------------
Write-Host ""
Write-Host "  Creando estructura del TPI en:" -ForegroundColor Cyan
Write-Host "  $Root" -ForegroundColor White
Write-Host ""

New-Dir $Root

# ------------------------------------------------------------------
# RAIZ
# ------------------------------------------------------------------
New-Placeholder -Path "$Root\README.md" -Content "# TPI - Optimizacion de la cadena logistica de ultima milla`n`nCopiar aqui el README.md del proyecto."

# ------------------------------------------------------------------
# ETAPA 1 - Problema, datos y arquitectura
# ------------------------------------------------------------------
$E1 = "$Root\etapa1-datos-arquitectura"

New-Placeholder -Path "$E1\README.md" -Content "# Etapa 1 - Problema, datos y arquitectura"

New-GitKeep -Dir "$E1\raw"              # CSV originales de Kaggle (Olist + Logistics and supply chain)
New-GitKeep -Dir "$E1\fleet_synthetic"  # CSV de flota generados por scripts\generate_fleet_dataset.py

New-Placeholder -Path "$E1\scripts\generate_fleet_dataset.py" -Content "# Copiar aqui generate_fleet_dataset.py"

New-Placeholder -Path "$E1\sql\01_ddl_olist.sql"            -Content "-- DDL: 9 tablas de Olist (claves primarias, foraneas y tipos)"
New-Placeholder -Path "$E1\sql\02_ddl_fleet.sql"            -Content "-- DDL: 5 tablas de flota sintetica"
New-Placeholder -Path "$E1\sql\03_import_data.sql"          -Content "-- COPY de los CSV y auditoria de volumenes"
New-Placeholder -Path "$E1\sql\03c_post_import.sql"         -Content "-- Diagnostico de calidad posterior a la carga"
New-Placeholder -Path "$E1\sql\03d_sanidad_flota.sql"       -Content "-- Chequeos de sensatez de la flota sintetica"
foreach ($q in 1..5) {
    New-Placeholder -Path "$E1\sql\04_q${q}_explain.sql"    -Content "-- Consulta analitica Q$q con EXPLAIN ANALYZE"
}
New-Placeholder -Path "$E1\sql\05_indices.sql"              -Content "-- Indices adicionales"
New-Placeholder -Path "$E1\sql\run_pipeline.ps1"            -Content "# Copiar aqui run_pipeline.ps1 de la Etapa 1"

New-Placeholder -Path "$E1\docs\propuesta_datasets_tpi.md"  -Content "# Propuesta de datasets`n`n## Problema y contexto`n## Fuentes de datos`n## Estructura de la base de datos`n## Preguntas analiticas`n## Resultados de performance`n## KPIs"
New-Placeholder -Path "$E1\docs\diccionario_datos_kpis.xlsx"

New-GitKeep -Dir "$E1\performance\explain_sin_indices"
New-GitKeep -Dir "$E1\performance\explain_con_indices"
New-GitKeep -Dir "$E1\performance\logs"

Write-Stage "etapa1-datos-arquitectura/"

# ------------------------------------------------------------------
# ETAPA 2 - Preparacion y analisis de los datos
# ------------------------------------------------------------------
$E2 = "$Root\etapa2-preparacion-eda"

New-Placeholder -Path "$E2\README.md" -Content "# Etapa 2 - Preparacion y analisis de los datos"

New-Placeholder -Path "$E2\sql\01_diagnostico_calidad.sql"     -Content "-- Diagnostico de calidad de datos (solo lectura)"
New-Placeholder -Path "$E2\sql\02_vistas_analiticas.sql"       -Content "-- Vistas y vista materializada del dataset analitico"
New-Placeholder -Path "$E2\sql\03_tablas_temporales.sql"       -Content "-- Tablas temporales para el analisis exploratorio"
New-Placeholder -Path "$E2\sql\04_explain_etapa2.sql"          -Content "-- Plan de ejecucion: vista logica vs materializada"
New-Placeholder -Path "$E2\sql\05_refresh_y_mantenimiento.sql" -Content "-- REFRESH CONCURRENTLY y auditoria de indices"
New-Placeholder -Path "$E2\sql\run_pipeline.ps1"                -Content "# Copiar aqui run_pipeline.ps1 de la Etapa 2"

New-Placeholder -Path "$E2\notebooks\01_limpieza.ipynb" -Content $EmptyNotebook
New-Placeholder -Path "$E2\notebooks\02_eda.ipynb"      -Content $EmptyNotebook

New-Placeholder -Path "$E2\output\.gitkeep" -Content "# dataset_analitico.parquet / .csv se generan al ejecutar 01_limpieza.ipynb"
New-GitKeep -Dir "$E2\figures"

New-Placeholder -Path "$E2\docs\informe_calidad_datos.md" -Content "# Informe de calidad de datos`n`n## Diagnostico`n## Transformaciones`n## Impacto en el volumen`n## Performance"
New-Placeholder -Path "$E2\docs\informe_etapa2.md"        -Content "# Informe de la Etapa 2"
New-Placeholder -Path "$E2\docs\conclusiones_eda.md"      -Content "# Conclusiones del analisis exploratorio"

Write-Stage "etapa2-preparacion-eda/"

# ------------------------------------------------------------------
# ETAPA 3 - Analisis inteligente y BI
# ------------------------------------------------------------------
$E3 = "$Root\etapa3-modelos-bi"

New-Placeholder -Path "$E3\README.md" -Content "# Etapa 3 - Analisis inteligente y Business Intelligence"

New-Placeholder -Path "$E3\notebooks\01_modelo_regresion_entrega.ipynb"     -Content $EmptyNotebook
New-Placeholder -Path "$E3\notebooks\02_modelo_clasificacion_demora.ipynb"  -Content $EmptyNotebook

New-Placeholder -Path "$E3\models\.gitkeep" -Content "# Modelos serializados (.pkl), generados al ejecutar los notebooks"
New-Placeholder -Path "$E3\sql\kpis.sql"    -Content "-- Una consulta por KPI, con nombre, formula y fuente"

New-Placeholder -Path "$E3\output\metricas_modelos.md" -Content "# Metricas de evaluacion`n`n## Modelo 1 - Regresion`n## Modelo 2 - Clasificacion"
New-Placeholder -Path "$E3\output\.gitkeep"            -Content "# Predicciones generadas por los notebooks"

New-GitKeep -Dir "$E3\figures"

New-Placeholder -Path "$E3\docs\informe_modelos.md" -Content "# Informe de modelos`n`n## Tecnica elegida`n## Justificacion`n## Variables utilizadas`n## Resultados`n## Evaluacion`n## Significado para el problema"

Write-Stage "etapa3-modelos-bi/"

# ------------------------------------------------------------------
# ETAPA 4 - Dashboard
# ------------------------------------------------------------------
$E4 = "$Root\etapa4-dashboard"

New-Placeholder -Path "$E4\README.md" -Content "# Etapa 4 - Dashboard integral para la toma de decisiones"

New-Placeholder -Path "$E4\pbix\.gitkeep"        -Content "# dashboard_logistica_ecommerce.pbix (Power BI), .twb (Tableau) o .xlsx"
New-Placeholder -Path "$E4\data_source\.gitkeep" -Content "# Copia estable del dataset analitico para conectar al dashboard"
New-Placeholder -Path "$E4\screenshots\.gitkeep" -Content "# vista_ejecutiva.png, vista_analitica.png, vista_decision.png"

Write-Stage "etapa4-dashboard/"

# ------------------------------------------------------------------
# ENTREGABLE FINAL (numerado segun los 7 puntos del enunciado)
# ------------------------------------------------------------------
$EF = "$Root\entregable-final"

New-Placeholder -Path "$EF\README.md" -Content (
    "# Entregable final`n`n" +
    "Copia consolidada para el Drive, numerada segun el enunciado:`n`n" +
    "1. 01_dataset_analitico_top1000.csv`n" +
    "2. 02_script_sql_completo.sql`n" +
    "3. 03_dataset_analitico.parquet`n" +
    "4. 04_analisis_y_modelos/  (notebooks, modelos y generate_fleet_dataset.py)`n" +
    "5. 05_dashboard_logistica_ecommerce.pbix`n" +
    "6. 06_informe_final.pdf  (maximo 5 paginas)`n" +
    "7. 07_diccionario_datos_kpis.xlsx`n")
New-GitKeep -Dir "$EF\04_analisis_y_modelos"

Write-Stage "entregable-final/"

# ------------------------------------------------------------------
# RESUMEN
# ------------------------------------------------------------------
$Dirs  = (Get-ChildItem -Path $Root -Recurse -Directory).Count
$Files = (Get-ChildItem -Path $Root -Recurse -File).Count

Write-Host ""
Write-Host "  ---------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Estructura lista." -ForegroundColor Cyan
Write-Host ""
Write-Host "  Archivos nuevos creados : $($script:Created)" -ForegroundColor White
Write-Host "  Carpetas en el proyecto : $Dirs" -ForegroundColor White
Write-Host "  Archivos en el proyecto : $Files" -ForegroundColor White
Write-Host ""
Write-Host "  Proximos pasos:" -ForegroundColor Yellow
Write-Host "  1. Copiar el README.md del proyecto en la raiz" -ForegroundColor White
Write-Host "  2. Descargar los CSV de Kaggle en etapa1-datos-arquitectura\raw\" -ForegroundColor White
Write-Host "  3. Copiar generate_fleet_dataset.py en etapa1-datos-arquitectura\scripts\ y ejecutarlo" -ForegroundColor White
Write-Host "  4. Copiar los scripts SQL y los run_pipeline.ps1 de cada etapa en sus carpetas sql\" -ForegroundColor White
Write-Host "  5. Seguir el paso a paso de la seccion 'Como reproducir' del README.md" -ForegroundColor White
Write-Host ""
Write-Host "  Ruta del proyecto: $Root" -ForegroundColor DarkGray
Write-Host "  ---------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
