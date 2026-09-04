<#
.SYNOPSIS
    FASE 2 del runbook SPB: cadenas de conexion en Web.config segun donde vive la base SBP.
    Nunca imprime contraseñas. Hace copia Web.config.origen antes de tocar nada.
    Edita el archivo como texto (solo las lineas afectadas) para no reformatear el XML.

.PARAMETER SqlHost        Caso A: nuevo host de SQL para SBP (ej. "localhost" o "localhost\SQLEXPRESS").
                          Sustituye 44.213.233.21 en las claves SqlServer y localhost_SBP_Connection.
                          Si se omite, es el caso B: las cadenas no se tocan, solo se verifica conectividad.
.PARAMETER CustomErrors   Valor para <customErrors mode="...">. Dejar "Off" durante las pruebas;
                          pasar a "RemoteOnly" al cerrar (lo hace 06-HTTPS-y-Cierre.ps1).

.EXAMPLE
    .\03-Configurar-WebConfig.ps1                       # solo diagnostico (caso B)
    .\03-Configurar-WebConfig.ps1 -SqlHost localhost    # caso A
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $WebConfig = 'C:\htdocs_apps\SPB\Web.config',
    [string] $SqlHost,
    [string] $SqlHostOrigen = '44.213.233.21',
    [ValidateSet('Off','RemoteOnly','On')] [string] $CustomErrors
)
#region Funciones comunes (copiadas en cada script para que sea autonomo)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ejecutar PowerShell como Administrador."
    }
}

function Get-InventarioDir {
    $base = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }
    $dir  = Join-Path $base 'inventario'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Start-Log([string] $Nombre) {
    $dir  = Get-InventarioDir
    $file = Join-Path $dir ("{0}-{1}-{2}.log" -f $Nombre, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
    try { Start-Transcript -Path $file -Append | Out-Null } catch {}
    return $file
}

function Stop-Log { try { Stop-Transcript | Out-Null } catch {} }

function Write-Paso([string] $Texto) { Write-Host "`n>> $Texto" -ForegroundColor Cyan }
function Write-Ok([string] $Texto)   { Write-Host "   OK  $Texto" -ForegroundColor Green }
function Write-Falta([string] $Texto){ Write-Host "   FALTA  $Texto" -ForegroundColor Yellow }

function Confirm-Accion([string] $Texto) {
    # Confirmacion explicita antes de acciones que el runbook marca como sensibles
    # (reinicio, SQL Server, DNS). Devuelve $true solo si el usuario escribe SI.
    $r = Read-Host "$Texto  Escribe SI para continuar"
    return ($r -eq 'SI')
}

function Enable-Tls12 {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

function Get-MaskedConnectionString([string] $Valor) {
    # Oculta Password=... y pwd=... para no filtrar secretos en logs ni en el chat
    return ($Valor -replace '(?i)(password|pwd)\s*=\s*[^;]*', '$1=***')
}

function Find-BackupFile([string] $Root, [string] $Pattern) {
    if (-not (Test-Path $Root)) { return $null }
    Get-ChildItem -Path $Root -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
}
#endregion
Assert-Admin
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $WebConfig)) { throw "No existe $WebConfig. Ejecuta primero 02-Desplegar-SPB.ps1" }

$raw = Get-Content $WebConfig -Raw
[xml] $xml = $raw
$appSettings = $xml.configuration.appSettings
$connStrings = $xml.configuration.connectionStrings

Write-Paso "Cadenas actuales (contraseñas ocultas)"
foreach ($k in 'SqlServer','SqlServer2') {
    $n = $appSettings.add | Where-Object key -eq $k
    if ($n) { Write-Host ("   appSettings/{0,-28} {1}" -f $k, (Get-MaskedConnectionString $n.value)) }
}
$cs = $connStrings.add | Where-Object name -eq 'localhost_SBP_Connection'
if ($cs) { Write-Host ("   connectionStrings/{0,-22} {1}" -f $cs.name, (Get-MaskedConnectionString $cs.connectionString)) }
$ce = $xml.configuration.'system.web'.customErrors
if ($ce) { Write-Host "   customErrors mode = $($ce.mode)" }

Write-Paso "Diagnostico SQL"
$t = Test-NetConnection $SqlHostOrigen -Port 1433 -WarningAction SilentlyContinue
Write-Host "   ${SqlHostOrigen}:1433 alcanzable = $($t.TcpTestSucceeded)"
$sqlSvc = Get-Service MSSQL* -ErrorAction SilentlyContinue
if ($sqlSvc) {
    Write-Host "   instancias locales: $(($sqlSvc | ForEach-Object { "$($_.Name) [$($_.Status)]" }) -join ', ')"
    if (Get-Command sqlcmd -ErrorAction SilentlyContinue) {
        $srv = if ($SqlHost) { $SqlHost } else { 'localhost' }
        $q = "SET NOCOUNT ON; SELECT 'DB '+name FROM sys.databases WHERE name IN ('SBP','BintecSmartBot'); SELECT 'LOGIN '+name FROM sys.sql_logins WHERE name IN ('sbp_admin','igs_app'); SELECT 'AUTH '+CASE SERVERPROPERTY('IsIntegratedSecurityOnly') WHEN 1 THEN 'SoloWindows' ELSE 'Mixta' END;"
        try { & sqlcmd -S $srv -E -h -1 -W -Q $q 2>&1 | ForEach-Object { Write-Host "   $_" } } catch { Write-Warning "sqlcmd fallo: $_" }
        Write-Host "   (SPB necesita: DB SBP + LOGIN sbp_admin + AUTH Mixta + TCP/IP habilitado)"
    }
} else { Write-Host "   sin SQL Server local" }

$nuevo = $raw
if ($SqlHost) {
    Write-Paso "Caso A: reemplazar host $SqlHostOrigen por $SqlHost"
    # Solo "Server=<origen>" (appSettings/SqlServer) y "data source=<origen>" (localhost_SBP_Connection).
    # SqlServer2 (BintecSmartBot) ya apunta a localhost y no se toca, igual que en el origen.
    $patron = "(?i)((?:Server|data source)\s*=\s*)" + [regex]::Escape($SqlHostOrigen) + "(?=[;""])"
    $coincidencias = [regex]::Matches($nuevo, $patron).Count
    if ($coincidencias -gt 0) {
        $nuevo = [regex]::Replace($nuevo, $patron, { param($m) $m.Groups[1].Value + $SqlHost })
        Write-Ok "$coincidencias cadena(s) apuntan ahora a $SqlHost"
    } else { Write-Host "   Web.config no contiene $SqlHostOrigen, sin cambios" }
} elseif ($raw -notmatch [regex]::Escape($SqlHostOrigen)) {
    Write-Paso "Cadenas de conexion sin cambios (ya no apuntan a $SqlHostOrigen)"
} else {
    Write-Paso "Caso B: la base sigue en $SqlHostOrigen, cadenas sin cambios"
    if (-not $t.TcpTestSucceeded) { Write-Warning "Este servidor NO alcanza ${SqlHostOrigen}:1433. Hay que abrir el firewall/Security Group del SQL para la IP de este servidor." }
}

if ($CustomErrors -and $ce -and $ce.mode -ne $CustomErrors) {
    $nuevo = [regex]::Replace($nuevo, '(?i)(<customErrors\b[^>]*\bmode\s*=\s*")[^"]*(")', "`${1}$CustomErrors`${2}", 1)
    Write-Ok "customErrors mode -> $CustomErrors"
}

if ($nuevo -ne $raw) {
    try { [xml] $null = $nuevo } catch { throw "El Web.config resultante no es XML valido; no se guarda. $_" }
    $bak = "$WebConfig.origen"
    if ($PSCmdlet.ShouldProcess($WebConfig, 'guardar cambios')) {
        if (-not (Test-Path $bak)) { Copy-Item $WebConfig $bak; Write-Ok "copia guardada en $bak" }
        [IO.File]::WriteAllText($WebConfig, $nuevo, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "Web.config actualizado"
        if (Get-Module -ListAvailable WebAdministration) { Import-Module WebAdministration; Restart-WebAppPool SPB -ErrorAction SilentlyContinue }
    }
} else { Write-Host "`nSin cambios en Web.config." }
