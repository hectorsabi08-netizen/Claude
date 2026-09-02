<#
.SYNOPSIS
    FASE 3 del runbook SPB: descomprime el paquete, crea pool y sitio en IIS, asigna permisos.

.DESCRIPTION
    Busca en -BackupRoot los archivos SPB-app.zip y SPB-documentos.zip. Si en lugar de zips el backup
    trae la carpeta SPB\ ya descomprimida, la copia con robocopy. Mantiene las rutas del origen:
      C:\htdocs_apps\SPB   y   C:\UploadTemp\documentos
    Crea el pool "SPB" (64-bit, v4.0 Integrated, AlwaysRunning) y el sitio "SPB" con bindings
      http *:80 sbp.bintec.io   y   http *:8080 (solo pruebas, se quita en 06-HTTPS-y-Cierre.ps1).

.EXAMPLE
    .\02-Desplegar-SPB.ps1 -BackupRoot "C:\htdocs_apps\BK\migracion-2026-09\OneDrive_2026-09-02\Server 54"
    .\02-Desplegar-SPB.ps1 -BackupRoot "..." -SkipDocumentos    # si los documentos ya estan copiados
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $BackupRoot = "C:\htdocs_apps\BK\migracion-2026-09\OneDrive_2026-09-02\Server 54",
    [string] $AppRoot    = 'C:\htdocs_apps',
    [string] $DocsRoot   = 'C:\UploadTemp',
    [string] $HostHeader = 'sbp.bintec.io',
    [int]    $PuertoPruebas = 8080,
    [switch] $SkipDocumentos,
    [switch] $StopDefaultWebSite
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
$log = Start-Log 'fase3-despliegue'
Import-Module WebAdministration

$spbPath  = Join-Path $AppRoot 'SPB'
$docsPath = Join-Path $DocsRoot 'documentos'

# ---------- 1. Contenido ----------
Write-Paso "1. Desplegar contenido desde $BackupRoot"
if (-not (Test-Path $BackupRoot)) { throw "No existe la carpeta de backup: $BackupRoot" }
New-Item -ItemType Directory -Force $AppRoot, $DocsRoot | Out-Null

$appZip  = Find-BackupFile $BackupRoot 'SPB-app.zip'
$appDir  = Get-ChildItem $BackupRoot -Recurse -Directory -Filter 'SPB' -ErrorAction SilentlyContinue |
           Where-Object { Test-Path (Join-Path $_.FullName 'Web.config') } | Select-Object -First 1
if ($appZip) {
    Write-Host "   SPB-app.zip -> $AppRoot"
    if ($PSCmdlet.ShouldProcess($appZip.FullName, "Expand-Archive a $AppRoot")) {
        Expand-Archive -Path $appZip.FullName -DestinationPath $AppRoot -Force
    }
} elseif ($appDir) {
    Write-Host "   carpeta $($appDir.FullName) -> $spbPath (robocopy)"
    if ($PSCmdlet.ShouldProcess($appDir.FullName, "robocopy a $spbPath")) {
        robocopy $appDir.FullName $spbPath /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy fallo con codigo $LASTEXITCODE" }
    }
} else { throw "No se encontro SPB-app.zip ni una carpeta SPB\ con Web.config dentro del backup." }

if (-not $SkipDocumentos) {
    $docZip = Find-BackupFile $BackupRoot 'SPB-documentos.zip'
    $docDir = Get-ChildItem $BackupRoot -Recurse -Directory -Filter 'documentos' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($docZip) {
        Write-Host "   SPB-documentos.zip -> $DocsRoot"
        if ($PSCmdlet.ShouldProcess($docZip.FullName, "Expand-Archive a $DocsRoot")) {
            Expand-Archive -Path $docZip.FullName -DestinationPath $DocsRoot -Force
        }
    } elseif ($docDir) {
        Write-Host "   carpeta $($docDir.FullName) -> $docsPath (robocopy)"
        if ($PSCmdlet.ShouldProcess($docDir.FullName, "robocopy a $docsPath")) {
            robocopy $docDir.FullName $docsPath /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy fallo con codigo $LASTEXITCODE" }
        }
    } else { Write-Warning "No se encontro SPB-documentos.zip ni carpeta documentos\. Se crea $docsPath vacio." }
}

if (-not $WhatIfPreference) {
    foreach ($p in (Join-Path $spbPath 'Web.config'), (Join-Path $spbPath 'bin\Operaciones.dll')) {
        if (Test-Path $p) { Write-Ok $p } else { throw "Falta $p tras descomprimir; revisar el paquete." }
    }
    $n = (Get-ChildItem $docsPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host "   documentos en ${docsPath}: $n archivos (origen: 1015)"
}

# ---------- 2. Unblock ----------
Write-Paso "2. Quitar marca 'descargado de Internet'"
if ($PSCmdlet.ShouldProcess($spbPath, 'Unblock-File recursivo')) {
    Get-ChildItem $spbPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    Write-Ok "Unblock-File aplicado"
}

# ---------- 3. Pool ----------
Write-Paso "3. Application pool SPB (64-bit, v4.0 Integrated, AlwaysRunning)"
if ($PSCmdlet.ShouldProcess('IIS:\AppPools\SPB', 'crear/configurar')) {
    if (-not (Test-Path IIS:\AppPools\SPB)) { New-WebAppPool -Name 'SPB' | Out-Null; Write-Ok "pool creado" } else { Write-Host "   pool ya existia, se reconfigura" }
    Set-ItemProperty IIS:\AppPools\SPB -Name managedRuntimeVersion   -Value 'v4.0'
    Set-ItemProperty IIS:\AppPools\SPB -Name managedPipelineMode     -Value 'Integrated'
    Set-ItemProperty IIS:\AppPools\SPB -Name enable32BitAppOnWin64   -Value $false
    Set-ItemProperty IIS:\AppPools\SPB -Name startMode               -Value 'AlwaysRunning'
    Set-ItemProperty IIS:\AppPools\SPB -Name processModel.idleTimeout -Value ([TimeSpan]::FromMinutes(0))
    Set-ItemProperty IIS:\AppPools\SPB -Name processModel.identityType -Value 'ApplicationPoolIdentity'
    Write-Ok "pool configurado"
}

# ---------- 4. Sitio ----------
Write-Paso "4. Sitio SPB: http *:80 $HostHeader  +  http *:$PuertoPruebas (pruebas)"
if ($PSCmdlet.ShouldProcess('IIS:\Sites\SPB', 'crear/configurar')) {
    if (-not (Get-Website -Name 'SPB' -ErrorAction SilentlyContinue)) {
        New-Website -Name 'SPB' -PhysicalPath $spbPath -ApplicationPool 'SPB' -Port 80 -HostHeader $HostHeader | Out-Null
        Write-Ok "sitio creado"
    } else {
        Set-ItemProperty 'IIS:\Sites\SPB' -Name physicalPath    -Value $spbPath
        Set-ItemProperty 'IIS:\Sites\SPB' -Name applicationPool -Value 'SPB'
        Write-Host "   sitio ya existia, se reconfigura ruta y pool"
    }
    $b80 = Get-WebBinding -Name 'SPB' -Protocol http | Where-Object bindingInformation -eq "*:80:$HostHeader"
    if (-not $b80) { New-WebBinding -Name 'SPB' -Protocol http -Port 80 -HostHeader $HostHeader }
    $bTest = Get-WebBinding -Name 'SPB' -Protocol http | Where-Object bindingInformation -eq "*:${PuertoPruebas}:"
    if (-not $bTest) { New-WebBinding -Name 'SPB' -Protocol http -Port $PuertoPruebas }
    Set-ItemProperty 'IIS:\Sites\SPB' -Name applicationDefaults.preloadEnabled -Value $true
    Write-Ok "bindings: $((Get-WebBinding -Name 'SPB' | ForEach-Object { $_.bindingInformation }) -join ' | ')"
}

# ---------- 5. Permisos ----------
Write-Paso "5. Permisos NTFS para 'IIS AppPool\SPB'"
$acct = 'IIS AppPool\SPB'
if ($PSCmdlet.ShouldProcess($spbPath, 'icacls')) {
    foreach ($p in $docsPath, (Join-Path $spbPath 'UploadImages'), (Join-Path $spbPath 'UploadTemp'), (Join-Path $spbPath 'App_Data')) {
        New-Item -ItemType Directory -Force $p | Out-Null
        icacls $p /grant "${acct}:(OI)(CI)M" /T /C /Q | Out-Null
        Write-Ok "Modify  $p"
    }
    icacls $spbPath /grant "${acct}:(OI)(CI)RX" /T /C /Q | Out-Null
    Write-Ok "ReadExecute  $spbPath"
}

# ---------- 6. Default Web Site ----------
if ($StopDefaultWebSite -and (Get-Website 'Default Web Site' -ErrorAction SilentlyContinue)) {
    Write-Paso "6. Detener Default Web Site"
    if ($PSCmdlet.ShouldProcess('Default Web Site', 'Stop-Website')) { Stop-Website 'Default Web Site'; Write-Ok "detenido" }
}

# ---------- Arranque ----------
Write-Paso "Arrancar pool y sitio"
if ($PSCmdlet.ShouldProcess('SPB', 'Start-WebAppPool / Start-Website')) {
    Start-WebAppPool 'SPB' -ErrorAction SilentlyContinue
    Start-Website 'SPB'
    Write-Ok "pool: $((Get-WebAppPoolState SPB).Value)   sitio: $((Get-Website SPB).State)"
}

Stop-Log
Write-Host "`nLog: $log"
Write-Host "Siguiente: 03-Configurar-WebConfig.ps1 (cadenas de conexion) y luego 04-Probar-SPB.ps1" -ForegroundColor Green
