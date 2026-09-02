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
