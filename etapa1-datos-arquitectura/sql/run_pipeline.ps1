<#
.SYNOPSIS
    Pipeline completo de la Etapa 1: base de datos, carga, validaciones y analisis de performance.

.DESCRIPTION
    Ejecuta en orden los scripts SQL de la Etapa 1 y guarda un log por paso en performance\logs.
    Para las 5 consultas analiticas (04_q1 a 04_q5) mide el tiempo SIN y CON los indices de
    05_indices.sql. Cada consulta se ejecuta una primera vez (se guarda el plan completo con BUFFERS)
    y despues -Repeticiones veces mas; el resumen usa la MEDIANA de esas repeticiones, que es
    estable frente a la cache. El resumen queda en performance\resumen_tiempos.csv.

    Pasos (-Step):
      all          todo lo siguiente, en orden
      ddl          01_ddl_olist.sql y 02_ddl_fleet.sql (recrea las tablas y borra sus indices)
      import       03_import_data.sql
      qa           03c_post_import.sql y 03d_sanidad_flota.sql
      explain_sin  consultas Q1-Q5 sin los indices de 05_indices.sql
      indices      05_indices.sql
      explain_con  consultas Q1-Q5 con los indices de 05_indices.sql

    Atencion: "explain_sin" solo es "sin indices" si 05_indices.sql todavia no se ejecuto.
    "-Step all" recrea las tablas, por lo que siempre parte sin esos indices.

.PARAMETER Step
    Paso a ejecutar (por defecto: all).

.PARAMETER Repeticiones
    Ejecuciones adicionales de cada consulta para calcular la mediana (por defecto: 3).

.EXAMPLE
    .\run_pipeline.ps1
    .\run_pipeline.ps1 -Step qa
    .\run_pipeline.ps1 -Step explain_con -Repeticiones 5

.NOTES
    Requisitos:
      - PostgreSQL 15 o superior corriendo, con la base creada:
          psql -U postgres -c "CREATE DATABASE olist_logistics_db;"
      - CSV de Olist y de Kaggle en etapa1-datos-arquitectura\raw
      - CSV de flota en etapa1-datos-arquitectura\fleet_synthetic (generate_fleet_dataset.py)
      - La carga usa \copy (del lado del cliente): no hace falta que el servidor PostgreSQL pueda
        leer la carpeta del proyecto ni el rol pg_read_server_files.
#>

param(
    [ValidateSet("all","ddl","import","qa","explain_sin","indices","explain_con")]
    [string]$Step         = "all",
    [string]$PgUser       = "postgres",
    [string]$PgDb         = "olist_logistics_db",
    [int]$Repeticiones    = 3,
    [string]$CsvOlist     = "",
    [string]$CsvFleet     = "",
    [string]$SqlDir       = $PSScriptRoot,
    [string]$LogDir       = "",
    [string]$ExplainDir   = "",
    [string]$PgPassword   = ""    # vacio: se usa $env:PGPASSWORD o se pide una sola vez
)

# (sin $ErrorActionPreference = "Stop": en PowerShell 5.1 rompe la redireccion 2>&1 de psql ante cualquier NOTICE)

# ------------------------------------------------------------------
# Rutas (relativas a la carpeta de la etapa) y codificacion
# ------------------------------------------------------------------
$Etapa1 = Split-Path $PSScriptRoot -Parent
function To-PsqlPath([string]$p) { return ([System.IO.Path]::GetFullPath($p)) -replace '\\', '/' }

if ($CsvOlist   -eq "") { $CsvOlist   = To-PsqlPath (Join-Path $Etapa1 "raw") }
if ($CsvFleet   -eq "") { $CsvFleet   = To-PsqlPath (Join-Path $Etapa1 "fleet_synthetic") }
if ($LogDir     -eq "") { $LogDir     = Join-Path $Etapa1 "performance\logs" }
if ($ExplainDir -eq "") { $ExplainDir = Join-Path $Etapa1 "performance" }

# psql escribe en UTF-8: evita acentos rotos en consola y en los logs
$env:PGCLIENTENCODING = "UTF8"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    throw "No se encontro psql en el PATH. Instalar PostgreSQL o agregar su carpeta bin al PATH."
}

# ------------------------------------------------------------------
# Password unico para todas las conexiones
# ------------------------------------------------------------------
if ($PgPassword -ne "") { $env:PGPASSWORD = $PgPassword }
elseif (-not $env:PGPASSWORD) {
    $secure = Read-Host -Prompt "Password del usuario '$PgUser' de PostgreSQL" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $env:PGPASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$ErrorCount = 0
$Resumen    = Join-Path $ExplainDir "resumen_tiempos.csv"

foreach ($d in @($LogDir, (Join-Path $ExplainDir "explain_sin_indices"), (Join-Path $ExplainDir "explain_con_indices"))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ------------------------------------------------------------------
# Funciones
# ------------------------------------------------------------------
function Count-Errors {
    param([string[]]$Lines)
    return @($Lines | Where-Object { $_ -match '^psql:.*ERROR:|^ERROR:' }).Count
}

function Run-Sql {
    param(
        [string]$Label,
        [string]$SqlFile,
        [string]$LogFile,
        [hashtable]$Vars = @{}
    )
    $varArgs = @()
    foreach ($k in $Vars.Keys) { $varArgs += "-v"; $varArgs += "${k}=$($Vars[$k])" }

    Write-Host ""
    Write-Host "[$Label]" -ForegroundColor Cyan
    Write-Host "  Script : $SqlFile"
    Write-Host "  Log    : $LogFile"

    $start = Get-Date
    # Desde la carpeta del script y con nombre relativo: los logs no incluyen rutas locales del equipo
    Push-Location (Split-Path $SqlFile -Parent)
    try { $out = & psql -U $PgUser -d $PgDb @varArgs -f (Split-Path $SqlFile -Leaf) 2>&1 | ForEach-Object { "$_" } }
    finally { Pop-Location }
    $out | Out-File -FilePath $LogFile -Encoding utf8
    $out | ForEach-Object { Write-Host $_ }
    $elapsed = ((Get-Date) - $start).TotalSeconds

    $n = Count-Errors $out
    $script:ErrorCount += $n
    if ($n -gt 0) { Write-Host "  ERRORES DETECTADOS: $n" -ForegroundColor Red }
    else          { Write-Host "  Completado en $([math]::Round($elapsed,1))s sin errores" -ForegroundColor Green }
}

function Stop-IfErrors {
    param([string]$Etapa)
    if ($script:ErrorCount -gt 0) {
        Write-Host ""
        Write-Host " ABORTADO: $($script:ErrorCount) error(es) en '$Etapa'. Revisar los logs de $LogDir (buscar 'ERROR:')." -ForegroundColor Red
        Write-Host " No se ejecutan los pasos siguientes: sus resultados no serian validos." -ForegroundColor Red
        exit 1
    }
}

function Get-ExecMs {
    param([string[]]$Lines)
    $m = [regex]::Match(($Lines -join "`n"), "Execution Time:\s*([0-9]+(?:\.[0-9]+)?)\s*ms")
    if ($m.Success) { return [double]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture) }
    return $null
}

function Get-Median {
    param([double[]]$Values)
    $s = $Values | Sort-Object
    $n = $s.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1) { return $s[($n - 1) / 2] }
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2
}

function Run-Explain {
    param([int]$Q, [string]$Phase)    # Phase: "sin" o "con"
    $sqlFile = Join-Path $SqlDir "04_q${Q}_explain.sql"
    $logFile = Join-Path $LogDir "04_q${Q}_explain_${Phase}_${timestamp}.log"
    $outFile = Join-Path $ExplainDir "explain_${Phase}_indices\q${Q}_${Phase}_idx.txt"

    Write-Host "  Q${Q} ($Phase indices)..." -NoNewline
    # 1) Primera ejecucion: plan completo con BUFFERS (muestra lecturas de disco)
    Push-Location (Split-Path $sqlFile -Parent)
    $first = & psql -U $PgUser -d $PgDb -f (Split-Path $sqlFile -Leaf) 2>&1 | ForEach-Object { "$_" }
    $first | Out-File -FilePath $logFile -Encoding utf8
    Copy-Item $logFile $outFile -Force
    $script:ErrorCount += (Count-Errors $first)

    # 2) Repeticiones: solo interesa el tiempo de ejecucion (cache caliente)
    $times = @()
    for ($i = 1; $i -le $Repeticiones; $i++) {
        $o = & psql -U $PgUser -d $PgDb -f (Split-Path $sqlFile -Leaf) 2>&1 | ForEach-Object { "$_" }
        $ms = Get-ExecMs $o
        if ($null -ne $ms) { $times += $ms }
    }
    Pop-Location
    $firstMs = Get-ExecMs $first
    $median  = Get-Median $times
    Write-Host (" primera {0} ms | mediana de {1}: {2} ms" -f $firstMs, $times.Count, $median) -ForegroundColor Green

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    return [pscustomobject]@{
        Consulta            = "Q$Q"
        Fase                = $Phase
        Primera_ms          = if ($null -ne $firstMs) { $firstMs.ToString("0.000", $inv) } else { "" }
        Mediana_caliente_ms = if ($null -ne $median)  { $median.ToString("0.000", $inv) }  else { "" }
        Repeticiones        = $times.Count
    }
}

function Save-Resumen {
    param($Rows, [string]$Phase)
    $old = @()
    if (Test-Path $Resumen) { $old = @(Import-Csv $Resumen | Where-Object { $_.Fase -ne $Phase }) }
    @($old) + @($Rows) | Export-Csv -Path $Resumen -NoTypeInformation -Encoding UTF8
}

function Show-Comparacion {
    if (-not (Test-Path $Resumen)) { return }
    $rows = Import-Csv $Resumen
    $inv  = [System.Globalization.CultureInfo]::InvariantCulture
    Write-Host ""
    Write-Host " Comparacion sin / con indices (mediana en cache caliente, ms)" -ForegroundColor Yellow
    foreach ($q in 1..5) {
        $s = $rows | Where-Object { $_.Consulta -eq "Q$q" -and $_.Fase -eq "sin" }
        $c = $rows | Where-Object { $_.Consulta -eq "Q$q" -and $_.Fase -eq "con" }
        if ($s -and $c) {
            $ms = [double]::Parse($s.Mediana_caliente_ms, $inv)
            $mc = [double]::Parse($c.Mediana_caliente_ms, $inv)
            Write-Host ("   Q{0}: sin {1,8:N1}  con {2,8:N1}  delta {3,6:N1} %" -f $q, $ms, $mc, (100 * ($mc - $ms) / $ms))
        }
    }
}

# ------------------------------------------------------------------
# Pipeline
# ------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================" -ForegroundColor Yellow
Write-Host " TPI Logistica - Pipeline Etapa 1 - $timestamp"      -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Yellow

if ($Step -in @("all","import")) {
    foreach ($d in @($CsvOlist, $CsvFleet)) {
        if (-not (Test-Path $d)) { throw "No existe la carpeta de datos: $d" }
    }
}

if ($Step -in @("all","ddl")) {
    Run-Sql -Label "01 DDL Olist + DDL AUDIT" `
            -SqlFile (Join-Path $SqlDir "01_ddl_olist.sql") `
            -LogFile (Join-Path $LogDir "01_ddl_olist_${timestamp}.log")
    Run-Sql -Label "02 DDL Flota + DDL AUDIT" `
            -SqlFile (Join-Path $SqlDir "02_ddl_fleet.sql") `
            -LogFile (Join-Path $LogDir "02_ddl_fleet_${timestamp}.log")
    Stop-IfErrors "01-02 DDL"
}

if ($Step -in @("all","import")) {
    Run-Sql -Label "03 Importacion de datos + DATA AUDIT" `
            -SqlFile (Join-Path $SqlDir "03_import_data.sql") `
            -LogFile (Join-Path $LogDir "03_import_${timestamp}.log") `
            -Vars @{ csv_olist = $CsvOlist; csv_fleet = $CsvFleet }
    Stop-IfErrors "03 importacion de datos"
}

if ($Step -in @("all","qa")) {
    Run-Sql -Label "03c Diagnostico de calidad post-import" `
            -SqlFile (Join-Path $SqlDir "03c_post_import.sql") `
            -LogFile (Join-Path $LogDir "03c_post_import_${timestamp}.log")
    Run-Sql -Label "03d Sanidad de la flota" `
            -SqlFile (Join-Path $SqlDir "03d_sanidad_flota.sql") `
            -LogFile (Join-Path $LogDir "03d_sanidad_flota_${timestamp}.log")
}

if ($Step -in @("all","explain_sin")) {
    Write-Host ""
    Write-Host "[EXPLAIN ANALYZE - sin los indices de 05_indices.sql]" -ForegroundColor Cyan
    $rows = foreach ($q in 1..5) { Run-Explain -Q $q -Phase "sin" }
    Save-Resumen -Rows $rows -Phase "sin"
}

if ($Step -in @("all","indices")) {
    Run-Sql -Label "05 Indices adicionales" `
            -SqlFile (Join-Path $SqlDir "05_indices.sql") `
            -LogFile (Join-Path $LogDir "05_indices_${timestamp}.log")
}

if ($Step -in @("all","explain_con")) {
    Write-Host ""
    Write-Host "[EXPLAIN ANALYZE - con los indices de 05_indices.sql]" -ForegroundColor Cyan
    $rows = foreach ($q in 1..5) { Run-Explain -Q $q -Phase "con" }
    Save-Resumen -Rows $rows -Phase "con"
}

# ------------------------------------------------------------------
# Resumen
# ------------------------------------------------------------------
Show-Comparacion

Write-Host ""
Write-Host "=================================================" -ForegroundColor Yellow
Write-Host " RESULTADO DEL PIPELINE"                            -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Yellow
if ($ErrorCount -eq 0) {
    Write-Host " OK - Pipeline completado sin errores." -ForegroundColor Green
} else {
    Write-Host " ATENCION - Se detectaron $ErrorCount errores. Buscar 'ERROR:' en los logs de $LogDir" -ForegroundColor Red
}
Write-Host ""
Write-Host " Archivos generados:"
Write-Host "   performance\logs\                          un log por paso"
Write-Host "   performance\explain_sin_indices\q1..q5     planes sin los indices de 05"
Write-Host "   performance\explain_con_indices\q1..q5     planes con los indices de 05"
Write-Host "   performance\resumen_tiempos.csv            primera ejecucion y mediana en cache caliente"
Write-Host ""
