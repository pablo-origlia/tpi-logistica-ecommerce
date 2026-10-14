<#
.SYNOPSIS
    Pipeline de la Etapa 2: vistas analiticas, diagnostico de calidad, analisis de performance y notebooks.

.DESCRIPTION
    Ejecuta en orden los scripts SQL de la Etapa 2 sobre olist_logistics_db, guarda sus salidas en docs\
    y ejecuta los notebooks 01_limpieza y 02_eda (que generan el dataset analitico, las figuras y los
    resultados del analisis exploratorio).

    Pasos (-Step):
      all          todo lo siguiente, en orden (los notebooks se omiten con -SinNotebooks)
      vistas       02_vistas_analiticas.sql          -> vistas y vista materializada del dataset analitico
      diagnostico  01_diagnostico_calidad.sql        -> docs\diagnostico_calidad.txt
      temporales   03_tablas_temporales.sql          -> docs\tablas_temporales.txt
      explain      04_explain_etapa2.sql             -> docs\explain_etapa2.txt y docs\resumen_tiempos_etapa2.csv
      refresh      05_refresh_y_mantenimiento.sql    -> docs\refresh_y_mantenimiento.txt
      notebooks    notebooks\01_limpieza.ipynb y 02_eda.ipynb (se ejecutan y se guardan con sus salidas)

    El analisis de performance (explain) ejecuta el script -Repeticiones veces y resume la MEDIANA de cada
    escenario; la salida completa guardada es la de la ultima corrida (cache caliente).
    Para medir en condiciones comparables conviene cerrar los programas pesados (Jupyter, navegador).

.PARAMETER Step
    Paso a ejecutar (por defecto: all).

.PARAMETER Repeticiones
    Corridas de 04_explain_etapa2.sql para calcular la mediana (por defecto: 3).

.PARAMETER SinNotebooks
    Con -Step all, omite la ejecucion de los notebooks.

.EXAMPLE
    .\run_pipeline.ps1
    .\run_pipeline.ps1 -Step diagnostico
    .\run_pipeline.ps1 -Step all -SinNotebooks

.NOTES
    Requisitos:
      - La Etapa 1 cargada en olist_logistics_db (etapa1-datos-arquitectura\sql\run_pipeline.ps1).
      - psql en el PATH. Para los notebooks: Python con jupyter, pandas, numpy, scipy, matplotlib, seaborn,
        scikit-learn, sqlalchemy, psycopg2-binary y pyarrow.
      - Los notebooks leen la conexion de la variable de entorno PG_URL; el pipeline la arma con la
        contrasena ingresada y la elimina al terminar.
#>

param(
    [ValidateSet("all","vistas","diagnostico","temporales","explain","refresh","notebooks")]
    [string]$Step       = "all",
    [string]$PgUser     = "postgres",
    [string]$PgDb       = "olist_logistics_db",
    [string]$PgHost     = "",
    [int]$PgPort        = 0,
    [int]$Repeticiones  = 3,
    [switch]$SinNotebooks,
    [string]$PgPassword = ""      # vacio: se usa $env:PGPASSWORD o se pide una sola vez
)

# (sin $ErrorActionPreference = "Stop": en PowerShell 5.1 rompe la redireccion 2>&1 de psql ante cualquier NOTICE)

# ------------------------------------------------------------------
# Rutas y codificacion
# ------------------------------------------------------------------
$SqlDir  = $PSScriptRoot
$Etapa2  = Split-Path $PSScriptRoot -Parent
$DocsDir = [System.IO.Path]::Combine($Etapa2, "docs")
$NbDir   = [System.IO.Path]::Combine($Etapa2, "notebooks")
$OutDir  = [System.IO.Path]::Combine($Etapa2, "output")
$Resumen = [System.IO.Path]::Combine($DocsDir, "resumen_tiempos_etapa2.csv")

$env:PGCLIENTENCODING = "UTF8"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

function Fail {
    param([string]$Message)
    Write-Host ""
    Write-Host " ERROR: $Message" -ForegroundColor Red
    exit 1
}

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    Fail "No se encontro psql en el PATH. Instalar PostgreSQL o agregar su carpeta bin al PATH."
}
if (-not (Test-Path $DocsDir)) { New-Item -ItemType Directory -Path $DocsDir -Force | Out-Null }

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

$ConnArgs = @("-U", $PgUser, "-d", $PgDb)
if ($PgHost -ne "") { $ConnArgs += @("-h", $PgHost) }
if ($PgPort -gt 0)  { $ConnArgs += @("-p", "$PgPort") }

$script:ErrorCount = 0

# ------------------------------------------------------------------
# Funciones
# ------------------------------------------------------------------
function Invoke-PsqlFile {
    # Ejecuta un script y devuelve sus lineas de salida (stdout y stderr)
    param([string]$File)
    # Se ejecuta desde la carpeta del script y con el nombre relativo: los mensajes de psql
    # ("psql:archivo.sql:9: NOTICE ...") no incluyen rutas locales del equipo.
    Push-Location (Split-Path $File -Parent)
    try { $out = & psql @ConnArgs -f (Split-Path $File -Leaf) 2>&1 | ForEach-Object { "$_" } }
    finally { Pop-Location }
    return @($out)
}

function Invoke-PsqlScalar {
    param([string]$Sql)
    $out = & psql @ConnArgs -At -c $Sql 2>&1 | ForEach-Object { "$_" }
    return (@($out) -join "").Trim()
}

function Save-Lines {
    param([string[]]$Lines, [string]$Path)
    [System.IO.File]::WriteAllLines($Path, [string[]]$Lines, $Utf8NoBom)
}

function Count-Errors {
    param([string[]]$Lines)
    return @($Lines | Where-Object { $_ -match '^psql:.*ERROR:|^ERROR:' }).Count
}

function Stop-IfErrors {
    param([string]$Etapa)
    if ($script:ErrorCount -gt 0) {
        Write-Host ""
        Write-Host " ABORTADO: $($script:ErrorCount) error(es) en '$Etapa'. Revisar la salida (buscar 'ERROR:')." -ForegroundColor Red
        Write-Host " No se ejecutan los pasos siguientes: sus resultados no serian validos." -ForegroundColor Red
        exit 1
    }
}

function Write-StepHeader {
    param([string]$Text)
    Write-Host ""
    Write-Host "[$Text]" -ForegroundColor Cyan
}

function Test-DatasetPrerequisite {
    # Verifica que la Etapa 1 este cargada y, salvo para 'vistas', que exista la vista materializada
    param([bool]$RequiereVista)
    $orders = Invoke-PsqlScalar "SELECT COUNT(*) FROM olist_orders"
    $fleet  = Invoke-PsqlScalar "SELECT COUNT(*) FROM fleet_deliveries"
    if (-not ($orders -match '^\d+$') -or [int64]$orders -eq 0 -or -not ($fleet -match '^\d+$') -or [int64]$fleet -eq 0) {
        Fail "La base '$PgDb' no tiene los datos de la Etapa 1 (olist_orders: '$orders', fleet_deliveries: '$fleet'). Ejecutar primero etapa1-datos-arquitectura\sql\run_pipeline.ps1."
    }
    Write-Host "  Base '$PgDb': olist_orders = $orders, fleet_deliveries = $fleet" -ForegroundColor DarkGray
    if ($RequiereVista) {
        $mv = Invoke-PsqlScalar "SELECT to_regclass('public.mv_dataset_analitico') IS NOT NULL"
        if ($mv -ne "t") { Fail "No existe mv_dataset_analitico. Ejecutar primero el paso 'vistas' (.\run_pipeline.ps1 -Step vistas)." }
    }
}

function Get-Median {
    param([double[]]$Values)
    $s = @($Values | Sort-Object)
    $n = $s.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1) { return $s[($n - 1) / 2] }
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2
}

function Get-ExplainTimes {
    # Tiempo de ejecucion de cada escenario de 04_explain_etapa2.sql (A-E: Execution Time; E2: \timing del REFRESH)
    param([string[]]$Lines)
    $res = @{}
    $label = $null
    foreach ($l in $Lines) {
        $m = [regex]::Match($l, '^=== (E2|[A-G])\)')
        if ($m.Success) { $label = $m.Groups[1].Value; continue }
        if ($null -eq $label) { continue }
        if ($label -in @("A","B","C","D","E")) {
            $t = [regex]::Match($l, 'Execution Time:\s*([0-9]+(?:\.[0-9]+)?)\s*ms')
            if ($t.Success) { $res[$label] = [double]::Parse($t.Groups[1].Value, $Inv) }
        }
        elseif ($label -eq "E2" -and -not $res.ContainsKey("E2")) {
            $t = [regex]::Match($l, '^Time:\s*([0-9]+(?:[.,][0-9]+)?)\s*ms')
            if ($t.Success) { $res["E2"] = [double]::Parse($t.Groups[1].Value.Replace(",", "."), $Inv) }
        }
    }
    return $res
}

# ------------------------------------------------------------------
# Pasos
# ------------------------------------------------------------------
function Run-Vistas {
    Write-StepHeader "02 Vistas analiticas"
    Test-DatasetPrerequisite $false
    $file = [System.IO.Path]::Combine($SqlDir, "02_vistas_analiticas.sql")
    $start = Get-Date
    $out = Invoke-PsqlFile $file
    $out | ForEach-Object { Write-Host "  $_" }
    $n = Count-Errors $out
    $script:ErrorCount += $n
    Stop-IfErrors "02 vistas analiticas"
    $rows = Invoke-PsqlScalar "SELECT COUNT(*) FROM mv_dataset_analitico"
    $cols = Invoke-PsqlScalar "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'vw_dataset_analitico'"
    Write-Host ("  Completado en {0}s: mv_dataset_analitico = {1} filas, {2} columnas" -f [math]::Round(((Get-Date) - $start).TotalSeconds, 1), $rows, $cols) -ForegroundColor Green
}

function Run-Diagnostico {
    Write-StepHeader "01 Diagnostico de calidad"
    Test-DatasetPrerequisite $false
    $file = [System.IO.Path]::Combine($SqlDir, "01_diagnostico_calidad.sql")
    $dest = [System.IO.Path]::Combine($DocsDir, "diagnostico_calidad.txt")
    $out = Invoke-PsqlFile $file
    Save-Lines $out $dest
    $script:ErrorCount += (Count-Errors $out)
    Stop-IfErrors "01 diagnostico de calidad"

    # Resumen: filas de la tabla de chequeos y chequeos "Debe ser 0" con afectados distintos de cero
    $total = 0; $conHallazgos = 0; $fallan = @()
    foreach ($l in $out) {
        $p = $l.Split('|')
        if ($p.Count -ne 6) { continue }
        $afect = $p[2].Trim()
        if ($afect -notmatch '^\d+$') { continue }
        $total++
        if ([int64]$afect -gt 0) { $conHallazgos++ }
        if ($p[5] -match 'Debe ser 0' -and [int64]$afect -gt 0) { $fallan += $p[1].Trim() }
    }
    Write-Host "  Salida: $dest"
    Write-Host "  $total chequeos, $conHallazgos con hallazgos." -ForegroundColor Green
    if ($fallan.Count -gt 0) {
        Write-Host "  ATENCION: $($fallan.Count) chequeo(s) 'Debe ser 0' con afectados distintos de cero:" -ForegroundColor Red
        $fallan | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    } else {
        Write-Host "  Todos los chequeos 'Debe ser 0' dan 0." -ForegroundColor Green
    }
}

function Run-Temporales {
    Write-StepHeader "03 Tablas temporales"
    Test-DatasetPrerequisite $true
    $file = [System.IO.Path]::Combine($SqlDir, "03_tablas_temporales.sql")
    $dest = [System.IO.Path]::Combine($DocsDir, "tablas_temporales.txt")
    $out = Invoke-PsqlFile $file
    Save-Lines $out $dest
    $script:ErrorCount += (Count-Errors $out)
    Stop-IfErrors "03 tablas temporales"
    Write-Host "  Salida: $dest" -ForegroundColor Green
}

function Run-Explain {
    Write-StepHeader "04 Analisis de performance (EXPLAIN ANALYZE, $Repeticiones corridas)"
    Test-DatasetPrerequisite $true
    $file = [System.IO.Path]::Combine($SqlDir, "04_explain_etapa2.sql")
    $dest = [System.IO.Path]::Combine($DocsDir, "explain_etapa2.txt")
    $all = @{}
    $last = @()
    for ($i = 1; $i -le $Repeticiones; $i++) {
        Write-Host "  Corrida $i de $Repeticiones..." -NoNewline
        $out = Invoke-PsqlFile $file
        $script:ErrorCount += (Count-Errors $out)
        Stop-IfErrors "04 explain (corrida $i)"
        $t = Get-ExplainTimes $out
        foreach ($k in $t.Keys) { if (-not $all.ContainsKey($k)) { $all[$k] = @() }; $all[$k] += $t[$k] }
        Write-Host (" A={0} B={1} C={2} D={3} E={4} E2={5} ms" -f $t["A"], $t["B"], $t["C"], $t["D"], $t["E"], $t["E2"])
        $last = $out
    }
    Save-Lines $last $dest

    $desc = [ordered]@{
        "A"  = "Vista logica: agregado por estado"
        "B"  = "Materializada: mismo agregado"
        "C"  = "Vista logica: filtro (SP + mes)"
        "D"  = "Materializada: filtro (SP + mes)"
        "E"  = "Construccion completa (costo de un REFRESH)"
        "E2" = "REFRESH MATERIALIZED VIEW"
    }
    $rows = foreach ($k in $desc.Keys) {
        if ($all.ContainsKey($k)) {
            $v = [double[]]$all[$k]
            [pscustomobject]@{
                Escenario   = $k
                Descripcion = $desc[$k]
                Mediana_ms  = (Get-Median $v).ToString("0.000", $Inv)
                Minimo_ms   = ($v | Measure-Object -Minimum).Minimum.ToString("0.000", $Inv)
                Corridas    = $v.Count
            }
        }
    }
    @($rows) | Export-Csv -Path $Resumen -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "  Escenario  Mediana (ms)  Minimo (ms)  Descripcion" -ForegroundColor Yellow
    foreach ($r in $rows) { Write-Host ("  {0,-9} {1,12} {2,12}  {3}" -f $r.Escenario, $r.Mediana_ms, $r.Minimo_ms, $r.Descripcion) }
    Write-Host ""
    Write-Host "  Salida completa de la ultima corrida: $dest"
    Write-Host "  Resumen de tiempos: $Resumen" -ForegroundColor Green
}

function Run-Refresh {
    Write-StepHeader "05 REFRESH CONCURRENTLY y auditoria de indices"
    Test-DatasetPrerequisite $true
    $file = [System.IO.Path]::Combine($SqlDir, "05_refresh_y_mantenimiento.sql")
    $dest = [System.IO.Path]::Combine($DocsDir, "refresh_y_mantenimiento.txt")
    $out = Invoke-PsqlFile $file
    Save-Lines $out $dest
    $script:ErrorCount += (Count-Errors $out)
    Stop-IfErrors "05 refresh y mantenimiento"
    $t = ($out | Where-Object { $_ -match '^Time:' } | Select-Object -First 3)
    Write-Host "  Salida: $dest" -ForegroundColor Green
    Write-Host "  Tiempos (SET / REFRESH CONCURRENTLY / ANALYZE): $($t -join ' | ')"
}

function Run-Notebooks {
    Write-StepHeader "Notebooks 01_limpieza y 02_eda"
    Test-DatasetPrerequisite $true
    if (-not (Get-Command jupyter -ErrorAction SilentlyContinue)) {
        Fail "No se encontro 'jupyter' en el PATH. Instalar: pip install jupyter pandas numpy scipy matplotlib seaborn scikit-learn sqlalchemy psycopg2-binary pyarrow"
    }
    $hostName = if ($PgHost -ne "") { $PgHost } else { "localhost" }
    $port     = if ($PgPort -gt 0) { $PgPort } else { 5432 }
    $pwdEnc   = [uri]::EscapeDataString($env:PGPASSWORD)
    $env:PG_URL = "postgresql+psycopg2://${PgUser}:${pwdEnc}@${hostName}:${port}/${PgDb}"
    try {
        foreach ($nb in @("01_limpieza.ipynb", "02_eda.ipynb")) {
            $path = [System.IO.Path]::Combine($NbDir, $nb)
            if (-not (Test-Path $path)) { throw "No existe el notebook: $path" }
            Write-Host "  Ejecutando $nb ..." -NoNewline
            $start = Get-Date
            & jupyter nbconvert --to notebook --execute --inplace --ExecutePreprocessor.timeout=3600 $path 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host " ERROR" -ForegroundColor Red
                throw "Fallo la ejecucion de $nb (codigo $LASTEXITCODE). Abrirlo en Jupyter para ver la celda con el error."
            }
            Write-Host (" OK ({0}s)" -f [math]::Round(((Get-Date) - $start).TotalSeconds, 0)) -ForegroundColor Green
        }
    }
    finally {
        Remove-Item Env:\PG_URL -ErrorAction SilentlyContinue
    }
    foreach ($f in @("dataset_analitico.parquet", "dataset_analitico.csv", "dataset_analitico_muestra1000.csv", "diagnostico_calidad.csv", "flota_mes_tipo.csv", "conductores.csv")) {
        $p = [System.IO.Path]::Combine($OutDir, $f)
        if (Test-Path $p) { Write-Host ("  output\{0,-36} {1,10:N0} KB" -f $f, ((Get-Item $p).Length / 1KB)) }
        else              { Write-Host "  output\$f   NO SE GENERO" -ForegroundColor Red }
    }
}

# ------------------------------------------------------------------
# Pipeline
# ------------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
Write-Host ""
Write-Host "=================================================" -ForegroundColor Yellow
Write-Host " TPI Logistica - Pipeline Etapa 2 - $timestamp"     -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Yellow

if ($Step -in @("all","vistas"))       { Run-Vistas }
if ($Step -in @("all","diagnostico"))  { Run-Diagnostico }
if ($Step -in @("all","temporales"))   { Run-Temporales }
if ($Step -in @("all","explain"))      { Run-Explain }
if ($Step -in @("all","refresh"))      { Run-Refresh }
if ($Step -eq "notebooks" -or ($Step -eq "all" -and -not $SinNotebooks)) {
    try { Run-Notebooks } catch { Fail $_.Exception.Message }
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Yellow
Write-Host " RESULTADO DEL PIPELINE"                            -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Yellow
if ($script:ErrorCount -eq 0) { Write-Host " OK - Pipeline completado sin errores." -ForegroundColor Green }
else { Write-Host " ATENCION - Se detectaron $($script:ErrorCount) errores." -ForegroundColor Red }
Write-Host ""
Write-Host " Archivos generados en docs\:"
Write-Host "   diagnostico_calidad.txt  tablas_temporales.txt  explain_etapa2.txt  refresh_y_mantenimiento.txt"
Write-Host "   resumen_tiempos_etapa2.csv   (mediana y minimo de cada escenario de performance)"
Write-Host " Notebooks: output\ (dataset analitico y tablas auxiliares) y figures\"
Write-Host ""
