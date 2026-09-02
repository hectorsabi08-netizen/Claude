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
# Localizar _comun.ps1 aunque $PSScriptRoot venga vacio (contenido pegado en consola, ISE "Run Selection")
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
             else { (Get-Location).Path }
$comun = Join-Path $scriptDir '_comun.ps1'
if (-not (Test-Path $comun)) { $comun = Join-Path (Get-Location).Path 'scripts\_comun.ps1' }
if (-not (Test-Path $comun)) {
    throw "No se encuentra _comun.ps1. Ejecuta el archivo desde la carpeta scripts del repositorio, por ejemplo:  cd C:\htdocs_apps\migracion-spb\scripts ; .\$(Split-Path -Leaf $MyInvocation.MyCommand.Path)   (no pegues el contenido en la consola)."
}
. $comun
Assert-Admin
$ErrorActionPreference = 'Continue'
Import-Module WebAdministration
$report = Join-Path (Get-InventarioDir) ("fase4-pruebas-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
$out = New-Object System.Text.StringBuilder
function R([string] $s) { [void]$out.AppendLine($s); Write-Host $s }

R "== FASE 4: pruebas SPB  ($(Get-Date))  host $env:COMPUTERNAME"

R "`n-- Estado IIS"
$site = Get-Website SPB -ErrorAction SilentlyContinue
if (-not $site) { R "   NO existe el sitio SPB. Ejecuta 02-Desplegar-SPB.ps1"; $out.ToString() | Out-File $report -Encoding UTF8; return }
R "   sitio SPB: $($site.State)   ruta: $($site.physicalPath)"
R "   pool  SPB: $((Get-WebAppPoolState SPB).Value)   runtime: $((Get-ItemProperty IIS:\AppPools\SPB).managedRuntimeVersion)   32bit: $((Get-ItemProperty IIS:\AppPools\SPB).enable32BitAppOnWin64)"
Get-WebBinding -Name SPB | ForEach-Object { R "   binding: $($_.protocol) $($_.bindingInformation)" }

R "`n-- Peticiones HTTP locales"
function Probar([string] $Url, [hashtable] $Headers = @{}) {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 0 -Headers $Headers -TimeoutSec 60 -ErrorAction Stop
        R ("   {0,-55} {1}  ({2} bytes)" -f $Url, $r.StatusCode, $r.RawContentLength)
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -in 301,302) { R ("   {0,-55} {1} -> {2}" -f $Url, $code, $_.Exception.Response.Headers['Location']) }
        elseif ($code) { R ("   {0,-55} {1}  ERROR" -f $Url, $code) }
        else { R ("   {0,-55} sin respuesta: {1}" -f $Url, $_.Exception.Message) }
    }
}
Probar "http://localhost:$PuertoPruebas/login.aspx"
Probar "http://localhost:$PuertoPruebas/default.aspx"
Probar "http://localhost:$PuertoPruebas/DXR.axd?r=1_1"
Probar "http://localhost/login.aspx" @{ Host = $HostHeader }

R "`n-- Ultimos errores ASP.NET / IIS en el Event Log (24 h)"
$ev = Get-WinEvent -FilterHashtable @{ LogName='Application'; Level=1,2; StartTime=(Get-Date).AddDays(-1) } -ErrorAction SilentlyContinue |
      Where-Object { $_.ProviderName -match 'ASP.NET|IIS|W3SVC|WAS|\.NET Runtime' } | Select-Object -First 5
if ($ev) { $ev | ForEach-Object { R ("   [{0}] {1}: {2}" -f $_.TimeCreated, $_.ProviderName, (($_.Message -split "`n")[0..2] -join ' ')) } } else { R "   (ninguno)" }

R "`n-- Permisos de escritura de 'IIS AppPool\SPB'"
foreach ($p in 'C:\UploadTemp\documentos','C:\htdocs_apps\SPB\UploadImages','C:\htdocs_apps\SPB\UploadTemp','C:\htdocs_apps\SPB\App_Data') {
    $ok = (Test-Path $p) -and ((icacls $p 2>$null) -match 'IIS AppPool\\SPB:.*\(M\)')
    R ("   {0,-45} {1}" -f $p, $(if ($ok) {'Modify OK'} else {'REVISAR'}))
}

R "`n-- Checklist manual (desde una PC con hosts -> $HostHeader o http://<IP>:$PuertoPruebas)"
@(
 "[ ] login.aspx carga con estilos DevExpress (tema Metropolis)",
 "[ ] Iniciar sesion (valida SQL)",
 "[ ] Abrir un reporte y exportar a PDF y a Excel (DevExpress, GemBox, Skia/Magick -> VC++)",
 "[ ] Subir documento con PathUploadControl -> aparece en C:\UploadTemp\documentos\<usuario>\",
 "[ ] Subir imagen (UploadImages)",
 "[ ] Pantalla con mapa Google Maps (si falla: restriccion de API key por referrer/IP)",
 "[ ] Operacion con adjuntos S3 (salida a s3.us-east-2.amazonaws.com:443)"
) | ForEach-Object { R "   $_" }

R "`n-- Si algo falla"
@(
 "500.19 / 500.21              -> Install-WindowsFeature Web-Asp-Net45 ; aspnet_regiis -iru",
 "Magick.Native / libSkiaSharp -> pool en 32 bits o falta VC++ x64",
 "Login failed 'sbp_admin'     -> autenticacion mixta o login inexistente (03-Configurar-WebConfig.ps1)",
 "Timeout SQL                  -> puerto 1433 cerrado o TCP/IP deshabilitado",
 "Acceso denegado al subir     -> permisos icacls (02-Desplegar-SPB.ps1 paso 5)",
 "Sin estilos                  -> requestFiltering fileExtensions .axd/.ashx",
 "Logs                         -> Event Viewer Application (ASP.NET 4.0.30319.0) y C:\inetpub\logs\LogFiles\W3SVC$($site.id)"
) | ForEach-Object { R "   $_" }

$out.ToString() | Out-File $report -Encoding UTF8
Write-Host "`nReporte guardado en: $report" -ForegroundColor Green
