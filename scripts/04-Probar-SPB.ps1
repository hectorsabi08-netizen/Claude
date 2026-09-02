<#
.SYNOPSIS
    FASE 4 del runbook SPB: pruebas HTTP desde el propio servidor, estado de IIS, errores recientes
    y checklist para las pruebas manuales desde el navegador.
    Genera inventario\fase4-pruebas-<host>-<fecha>.txt para subir al repositorio.
#>
[CmdletBinding()]
param(
    [int]    $PuertoPruebas = 8080,
    [string] $HostHeader = 'sbp.bintec.io'
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
$ErrorActionPreference = 'Continue'
Import-Module WebAdministration
$report = Join-Path (Get-InventarioDir) ("fase4-pruebas-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
$out = New-Object System.Text.StringBuilder
function Write-Rep([string] $s) { [void]$out.AppendLine($s); Write-Host $s }

Write-Rep "== FASE 4: pruebas SPB  ($(Get-Date))  host $env:COMPUTERNAME"

Write-Rep "`n-- Estado IIS"
$site = Get-Website SPB -ErrorAction SilentlyContinue
if (-not $site) { Write-Rep "   NO existe el sitio SPB. Ejecuta 02-Desplegar-SPB.ps1"; $out.ToString() | Out-File $report -Encoding UTF8; return }
Write-Rep "   sitio SPB: $($site.State)   ruta: $($site.physicalPath)"
Write-Rep "   pool  SPB: $((Get-WebAppPoolState SPB).Value)   runtime: $((Get-ItemProperty IIS:\AppPools\SPB).managedRuntimeVersion)   32bit: $((Get-ItemProperty IIS:\AppPools\SPB).enable32BitAppOnWin64)"
Get-WebBinding -Name SPB | ForEach-Object { Write-Rep "   binding: $($_.protocol) $($_.bindingInformation)" }

Write-Rep "`n-- Peticiones HTTP locales"
function Probar([string] $Url, [hashtable] $Headers = @{}) {
    # HttpWebRequest directo: Invoke-WebRequest -MaximumRedirection 0 falla en PowerShell 5.1 con 302
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.AllowAutoRedirect = $false; $req.Timeout = 60000; $req.UserAgent = 'Mozilla/5.0 (spb-check)'
        foreach ($k in $Headers.Keys) { if ($k -eq 'Host') { $req.Host = $Headers[$k] } else { $req.Headers[$k] = $Headers[$k] } }
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode; $len = $resp.ContentLength; $loc = $resp.Headers['Location']; $resp.Close()
        if ($code -in 301,302) { Write-Rep ("   {0,-55} {1} -> {2}" -f $Url, $code, $loc) }
        else { Write-Rep ("   {0,-55} {1}  ({2} bytes)" -f $Url, $code, $len) }
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($r) { $code = [int]$r.StatusCode; $loc = $r.Headers['Location']; $r.Close()
            if ($code -in 301,302) { Write-Rep ("   {0,-55} {1} -> {2}" -f $Url, $code, $loc) }
            else { Write-Rep ("   {0,-55} {1}  ERROR" -f $Url, $code) } }
        else { Write-Rep ("   {0,-55} sin respuesta: {1}" -f $Url, $_.Exception.Message) }
    } catch { Write-Rep ("   {0,-55} sin respuesta: {1}" -f $Url, $_.Exception.Message) }
}
Probar "http://localhost:$PuertoPruebas/login.aspx"
Probar "http://localhost:$PuertoPruebas/default.aspx"
Probar "http://localhost:$PuertoPruebas/DXR.axd?r=1_1"
Probar "http://localhost/login.aspx" @{ Host = $HostHeader }

Write-Rep "`n-- Ultimos errores ASP.NET / IIS en el Event Log (24 h)"
$ev = Get-WinEvent -FilterHashtable @{ LogName='Application'; Level=1,2; StartTime=(Get-Date).AddDays(-1) } -ErrorAction SilentlyContinue |
      Where-Object { $_.ProviderName -match 'ASP.NET|IIS|W3SVC|WAS|\.NET Runtime' } | Select-Object -First 5
if ($ev) { $ev | ForEach-Object { Write-Rep ("   [{0}] {1}: {2}" -f $_.TimeCreated, $_.ProviderName, (($_.Message -split "`n")[0..2] -join ' ')) } } else { Write-Rep "   (ninguno)" }

Write-Rep "`n-- Permisos de escritura de 'IIS AppPool\SPB'"
foreach ($p in 'C:\UploadTemp\documentos','C:\htdocs_apps\SPB\UploadImages','C:\htdocs_apps\SPB\UploadTemp','C:\htdocs_apps\SPB\App_Data') {
    $ok = (Test-Path $p) -and ((icacls $p 2>$null) -match 'IIS AppPool\\SPB:.*\(M\)')
    Write-Rep ("   {0,-45} {1}" -f $p, $(if ($ok) {'Modify OK'} else {'REVISAR'}))
}

Write-Rep "`n-- Checklist manual (desde una PC con hosts -> $HostHeader o http://<IP>:$PuertoPruebas)"
@(
 "[ ] login.aspx carga con estilos DevExpress (tema Metropolis)",
 "[ ] Iniciar sesion (valida SQL)",
 "[ ] Abrir un reporte y exportar a PDF y a Excel (DevExpress, GemBox, Skia/Magick -> VC++)",
 "[ ] Subir documento con PathUploadControl -> aparece en C:\UploadTemp\documentos\<usuario>\",
 "[ ] Subir imagen (UploadImages)",
 "[ ] Pantalla con mapa Google Maps (si falla: restriccion de API key por referrer/IP)",
 "[ ] Operacion con adjuntos S3 (salida a s3.us-east-2.amazonaws.com:443)"
) | ForEach-Object { Write-Rep "   $_" }

Write-Rep "`n-- Si algo falla"
@(
 "500.19 / 500.21              -> Install-WindowsFeature Web-Asp-Net45 ; aspnet_regiis -iru",
 "Magick.Native / libSkiaSharp -> pool en 32 bits o falta VC++ x64",
 "Login failed 'sbp_admin'     -> autenticacion mixta o login inexistente (03-Configurar-WebConfig.ps1)",
 "Timeout SQL                  -> puerto 1433 cerrado o TCP/IP deshabilitado",
 "Acceso denegado al subir     -> permisos icacls (02-Desplegar-SPB.ps1 paso 5)",
 "Sin estilos                  -> requestFiltering fileExtensions .axd/.ashx",
 "Logs                         -> Event Viewer Application (ASP.NET 4.0.30319.0) y C:\inetpub\logs\LogFiles\W3SVC$($site.id)"
) | ForEach-Object { Write-Rep "   $_" }

$out.ToString() | Out-File $report -Encoding UTF8
Write-Host "`nReporte guardado en: $report" -ForegroundColor Green
