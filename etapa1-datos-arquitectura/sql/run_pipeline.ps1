# =============================================================
# run_pipeline.ps1
# Pipeline completo de Etapa 1 — TPI Logistica E-Commerce
# Maestria en Ciencias de Datos, UCASAL 2026
# =============================================================
# USO:
#   .\run_pipeline.ps1
#   .\run_pipeline.ps1 -Step import        (solo paso de import)
#   .\run_pipeline.ps1 -Step explain_sin   (solo EXPLAIN sin indices)
#   .\run_pipeline.ps1 -Step indices       (solo indices)
#   .\run_pipeline.ps1 -Step explain_con   (solo EXPLAIN con indices)
#
# PREREQUISITOS:
#   - PostgreSQL 15 instalado y corriendo
#   - Base olist_logistics_db creada: psql -U postgres -c "CREATE DATABASE olist_logistics_db;"
#   - CSV de Olist en $CsvOlist
#   - CSV de flota generados en $CsvFleet (ejecutar generate_fleet_dataset.py primero)
# =============================================================

param(
    [string]$Step = "all",
    [string]$PgUser    = "postgres",
    [string]$PgDb      = "olist_logistics_db",
    [string]$CsvOlist  = "C:/poriglia/tpi-logistica-ecommerce/etapa1-datos-arquitectura/raw",
    [string]$CsvFleet  = "C:/poriglia/tpi-logistica-ecommerce/etapa1-datos-arquitectura/fleet_synthetic",
    [string]$SqlDir    = $PSScriptRoot,
    [string]$LogDir    = (Join-Path $PSScriptRoot "..\performance\logs"),
    [string]$ExplainDir= (Join-Path $PSScriptRoot "..\performance"),
    [string]$PgPassword = ""   # dejar vacio para que el script pida el password una vez
)

# =============================================================
# Setup — password unico para todas las conexiones psql
# =============================================================
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$ErrorCount = 0

# Pedir el password una sola vez y exportarlo como variable de entorno.
# psql lo lee automaticamente desde $env:PGPASSWORD sin volver a pedirlo.
if ($PgPassword -eq "") {
    $securePass = Read-Host -Prompt "Password para el usuario '$PgUser' de PostgreSQL" `
                            -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    $PgPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}
$env:PGPASSWORD = $PgPassword

# Crear directorio de logs si no existe
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
foreach ($subdir in @("explain_sin_indices","explain_con_indices")) {
    $path = Join-Path $ExplainDir $subdir
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

# Funcion: ejecutar un script psql y guardar log
function Run-Sql {
    param(
        [string]$Label,
        [string]$SqlFile,
        [string]$LogFile,
        [hashtable]$Vars = @{}
    )

    $varArgs = @()
    foreach ($k in $Vars.Keys) {
        $varArgs += "-v"
        $varArgs += "${k}=$($Vars[$k])"
    }

    Write-Host ""
    Write-Host "[$Label]" -ForegroundColor Cyan
    Write-Host "  Script : $SqlFile"
    Write-Host "  Log    : $LogFile"

    $start = Get-Date
    & psql -U $PgUser -d $PgDb @varArgs -f $SqlFile 2>&1 | Tee-Object -FilePath $LogFile
    $elapsed = ((Get-Date) - $start).TotalSeconds

    # Detectar errores en el output del log
    $errors = Select-String -Path $LogFile -Pattern "^psql:.*ERROR:|^ERROR:" | Measure-Object
    $script:ErrorCount += $errors.Count

    if ($errors.Count -gt 0) {
        Write-Host "  ERRORES DETECTADOS: $($errors.Count)" -ForegroundColor Red
    } else {
        Write-Host "  Completado en $([math]::Round($elapsed,1))s sin errores" -ForegroundColor Green
    }
    return $errors.Count
}

# Funcion: ejecutar EXPLAIN para una consulta y guardar
function Run-Explain {
    param(
        [string]$Q,
        [string]$Phase    # "sin" o "con"
    )
    $sqlFile = Join-Path $SqlDir "04_q${Q}_explain.sql"
    $outFile = Join-Path $ExplainDir "explain_${Phase}_indices\q${Q}_${Phase}_idx.txt"
    $logFile = Join-Path $LogDir "04_q${Q}_explain_${Phase}_${timestamp}.log"

    Write-Host "  Q${Q} ($Phase indices)..." -NoNewline
    $start = Get-Date
    & psql -U $PgUser -d $PgDb -f $sqlFile 2>&1 |
        Tee-Object -FilePath $logFile |
        Out-File -FilePath $outFile -Encoding utf8
    $elapsed = ((Get-Date) - $start).TotalSeconds
    Write-Host " $([math]::Round($elapsed,1))s" -ForegroundColor Green
}

# =============================================================
# PIPELINE
# =============================================================

Write-Host ""
Write-Host "=================================================" -ForegroundColor Yellow
Write-Host " TPI Logistica — Pipeline Etapa 1 — $timestamp"  -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Yellow

# PASO 1: DDL Olist (incluye correcciones de calidad + DDL AUDIT)
if ($Step -in @("all","ddl")) {
    Run-Sql -Label "01 DDL Olist + fixes calidad + DDL AUDIT" `
            -SqlFile (Join-Path $SqlDir "01_ddl_olist.sql") `
            -LogFile (Join-Path $LogDir "01_ddl_olist_${timestamp}.log")
}

# PASO 2: DDL Flota (incluye DDL AUDIT)
if ($Step -in @("all","ddl")) {
    Run-Sql -Label "02 DDL Flota + DDL AUDIT" `
            -SqlFile (Join-Path $SqlDir "02_ddl_fleet.sql") `
            -LogFile (Join-Path $LogDir "02_ddl_fleet_${timestamp}.log")
}

# PASO 3: Import datos (incluye DATA AUDIT expandido)
if ($Step -in @("all","import")) {
    Run-Sql -Label "03 Import datos + DATA AUDIT" `
            -SqlFile (Join-Path $SqlDir "03_import_data.sql") `
            -LogFile (Join-Path $LogDir "03_import_${timestamp}.log") `
            -Vars @{
                csv_olist  = $CsvOlist
                csv_fleet  = $CsvFleet
            }
}

# PASO 4: QA profundo de calidad (se guarda como archivo de referencia para Etapa 2)
if ($Step -in @("all","import","qa")) {
    Run-Sql -Label "03c QA profundo post-import" `
            -SqlFile (Join-Path $SqlDir "03c_post_import.sql") `
            -LogFile (Join-Path $LogDir "03c_post_import_${timestamp}.log")

    # Copiar el log como referencia permanente para Etapa 2
    $qaRef = Join-Path $ExplainDir "post_import_diagnostico.txt"
    Copy-Item (Join-Path $LogDir "03c_post_import_${timestamp}.log") $qaRef -Force
    Write-Host "  Diagnostico guardado en: $qaRef" -ForegroundColor DarkGray
}

# PASO 5: EXPLAIN ANALYZE sin indices
if ($Step -in @("all","explain_sin")) {
    Write-Host ""
    Write-Host "[EXPLAIN ANALYZE — sin indices adicionales]" -ForegroundColor Cyan
    foreach ($q in @(1,2,3,4,5)) {
        Run-Explain -Q $q -Phase "sin"
    }
}

# PASO 6: Crear indices adicionales
if ($Step -in @("all","indices")) {
    Run-Sql -Label "05 Indices adicionales" `
            -SqlFile (Join-Path $SqlDir "05_indices.sql") `
            -LogFile (Join-Path $LogDir "05_indices_${timestamp}.log")
}

# PASO 7: EXPLAIN ANALYZE con indices
if ($Step -in @("all","explain_con")) {
    Write-Host ""
    Write-Host "[EXPLAIN ANALYZE — con indices adicionales]" -ForegroundColor Cyan
    foreach ($q in @(1,2,3,4,5)) {
        Run-Explain -Q $q -Phase "con"
    }
}

# =============================================================
# RESUMEN FINAL
# =============================================================
Write-Host ""
Write-Host "=================================================" -ForegroundColor Yellow
Write-Host " RESULTADO DEL PIPELINE"                          -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Yellow

if ($ErrorCount -eq 0) {
    Write-Host " OK — Pipeline completado sin errores." -ForegroundColor Green
    Write-Host " Logs en: $LogDir"
} else {
    Write-Host " ATENCION — Se detectaron $ErrorCount errores." -ForegroundColor Red
    Write-Host " Revisar logs en: $LogDir"
    Write-Host " Buscar lineas con 'ERROR:' en cada archivo .log"
}

Write-Host ""
Write-Host " Archivos generados:"
Write-Host "   explain_sin_indices/q1_sin_idx.txt ... q5_sin_idx.txt"
Write-Host "   explain_con_indices/q1_con_idx.txt ... q5_con_idx.txt"
Write-Host "   post_import_diagnostico.txt (insumo Etapa 2)"
Write-Host ""
