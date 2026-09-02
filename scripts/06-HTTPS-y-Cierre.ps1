<#
.SYNOPSIS
    FASE 6 del runbook SPB: certificado Let's Encrypt con win-acme y cierre (quitar binding 8080,
    customErrors RemoteOnly). Ejecutar SOLO cuando el DNS de sbp.bintec.io ya apunte a este servidor.

.EXAMPLE
    .\06-HTTPS-y-Cierre.ps1 -Email admin@bintec.io
    .\06-HTTPS-y-Cierre.ps1 -Email admin@bintec.io -SoloCierre      # ya hay https, solo limpiar
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $HostHeader = 'sbp.bintec.io',
    [string] $Email,
    [int]    $PuertoPruebas = 8080,
    [switch] $SoloCierre,
    [switch] $RedirigirHttps
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
$log = Start-Log 'fase6-https'
Import-Module WebAdministration
$site = Get-Website SPB
if (-not $site) { throw "No existe el sitio SPB." }

if (-not $SoloCierre) {
    Write-Paso "Comprobar que $HostHeader resuelve a este servidor"
    $ips = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' }).IPAddress
    $dns = (Resolve-DnsName $HostHeader -Type A -ErrorAction SilentlyContinue).IPAddress
    Write-Host "   DNS A: $($dns -join ', ')   IPs locales: $($ips -join ', ')"
    Write-Host "   (si el servidor esta detras de NAT, la IP publica no coincide con la local; valida desde fuera)"
    if (-not (Confirm-Accion "El DNS de $HostHeader ya apunta a este servidor y el puerto 80 esta abierto desde Internet?")) { Stop-Log; return }

    Write-Paso "Emitir certificado con win-acme (HTTP-01)"
    if (-not (Test-Path 'C:\wacs\wacs.exe')) { throw "Falta C:\wacs\wacs.exe (01-Instalar-Prerrequisitos.ps1)" }
    if (-not $Email) { $Email = Read-Host "Correo para la cuenta Let's Encrypt" }
    $wacsArgs = @('--source','iis','--siteid',$site.id,'--host',$HostHeader,'--store','certificatestore','--certificatestore','WebHosting',
              '--installation','iis','--accepttos','--emailaddress',$Email)
    if ($PSCmdlet.ShouldProcess('C:\wacs\wacs.exe', ($wacsArgs -join ' '))) {
        & 'C:\wacs\wacs.exe' @wacsArgs
        if ($LASTEXITCODE -ne 0) { Write-Warning "wacs.exe devolvio $LASTEXITCODE; revisa C:\ProgramData\win-acme\*\Log" }
    }
    Write-Paso "Bindings https"
    Get-WebBinding -Name SPB -Protocol https | ForEach-Object { Write-Ok "$($_.bindingInformation) sslFlags=$($_.sslFlags)" }
    netsh http show sslcert | Select-String -Pattern 'Hostname:IP|Certificate Hash|Application ID' | ForEach-Object { Write-Host "   $_" }
}

if ($RedirigirHttps) {
    Write-Paso "Redireccion HTTP -> HTTPS (URL Rewrite)"
    if (-not (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\URL Rewrite' -ErrorAction SilentlyContinue)) { Write-Warning "URL Rewrite no instalado; omitido." }
    elseif ($PSCmdlet.ShouldProcess('IIS:\Sites\SPB', 'regla rewrite https')) {
        $psPath = 'IIS:\Sites\SPB'; $rules = 'system.webServer/rewrite/rules'
        if (-not (Get-WebConfigurationProperty -PSPath $psPath -Filter "$rules/rule[@name='HTTPS']" -Name name -ErrorAction SilentlyContinue)) {
            Add-WebConfigurationProperty -PSPath $psPath -Filter $rules -Name '.' -Value @{ name='HTTPS'; stopProcessing='True' }
            Set-WebConfigurationProperty -PSPath $psPath -Filter "$rules/rule[@name='HTTPS']/match" -Name url -Value '(.*)'
            Add-WebConfigurationProperty -PSPath $psPath -Filter "$rules/rule[@name='HTTPS']/conditions" -Name '.' -Value @{ input='{HTTPS}'; pattern='off' }
            Add-WebConfigurationProperty -PSPath $psPath -Filter "$rules/rule[@name='HTTPS']/conditions" -Name '.' -Value @{ input='{SERVER_PORT}'; pattern="^$PuertoPruebas`$"; negate='True' }
            Set-WebConfigurationProperty -PSPath $psPath -Filter "$rules/rule[@name='HTTPS']/action" -Name type -Value 'Redirect'
            Set-WebConfigurationProperty -PSPath $psPath -Filter "$rules/rule[@name='HTTPS']/action" -Name url -Value 'https://{HTTP_HOST}/{R:1}'
            Write-Ok "regla HTTPS creada en web.config del sitio"
        } else { Write-Ok "regla HTTPS ya existia" }
    }
}

Write-Paso "Cierre: quitar binding y regla de pruebas $PuertoPruebas, customErrors RemoteOnly"
if ($PSCmdlet.ShouldProcess("SPB :$PuertoPruebas", 'Remove-WebBinding')) {
    Get-WebBinding -Name SPB -Protocol http | Where-Object bindingInformation -eq "*:${PuertoPruebas}:" | Remove-WebBinding
    Get-NetFirewallRule -DisplayName "IIS pruebas $PuertoPruebas (temporal)" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Ok "binding y regla de firewall $PuertoPruebas eliminados"
}
& (Join-Path $scriptDir "03-Configurar-WebConfig.ps1") -CustomErrors RemoteOnly

Write-Paso "Configuracion final del sitio"
& "$env:windir\System32\inetsrv\appcmd.exe" list site SPB /config | Tee-Object -FilePath (Join-Path (Get-InventarioDir) "sitio-SPB-final-$env:COMPUTERNAME.xml")
Stop-Log
Write-Host "`nLog: $log" -ForegroundColor Green
Write-Host "Pendientes del usuario: Security Group 80/443, restriccion de la API key de Google Maps al nuevo host, rotacion de secretos, migracion de las otras apps."
