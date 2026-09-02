<#
.SYNOPSIS
    FASE 1 del runbook SPB: instala lo que falte en Windows Server 2019.
    Solo instala lo que no esta presente. Pide confirmacion antes de reiniciar.

.PARAMETER SkipDotNet48     No instalar .NET Framework 4.8.
.PARAMETER SkipVcRedist     No instalar VC++ 2015-2022 x64.
.PARAMETER SkipUrlRewrite   No instalar URL Rewrite 2.1 (opcional para SPB).
.PARAMETER SkipWinAcme      No descargar win-acme a C:\wacs.
.PARAMETER Descargas        Carpeta con instaladores ya descargados (si el servidor no tiene Internet):
                            ndp48.exe, vc_redist.x64.exe, rewrite_amd64_en-US.msi, win-acme.v2.2.9.*.x64.pluggable.zip

.EXAMPLE
    .\01-Instalar-Prerrequisitos.ps1
    .\01-Instalar-Prerrequisitos.ps1 -Descargas "D:\instaladores" -SkipUrlRewrite
#>
[CmdletBinding()]
param(
    [switch] $SkipDotNet48,
    [switch] $SkipVcRedist,
    [switch] $SkipUrlRewrite,
    [switch] $SkipWinAcme,
    [string] $Descargas
)
. "$PSScriptRoot\_comun.ps1"
Assert-Admin
$ErrorActionPreference = 'Stop'
$log = Start-Log 'fase1-instalacion'
Enable-Tls12
$reinicio = $false

function Get-Instalador([string] $Nombre, [string] $Url) {
    if ($Descargas) {
        $local = Get-ChildItem $Descargas -File -ErrorAction SilentlyContinue | Where-Object Name -like $Nombre | Select-Object -First 1
        if ($local) { return $local.FullName }
    }
    $dest = Join-Path $env:TEMP ($Nombre -replace '\*', 'x')
    Write-Host "   descargando $Url"
    Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing
    return $dest
}

# ---------- 4.1 Roles IIS ----------
Write-Paso "4.1 Roles de IIS para SPB"
$features = 'Web-Server','Web-Common-Http','Web-Default-Doc','Web-Dir-Browsing','Web-Http-Errors','Web-Static-Content',
            'Web-Health','Web-Http-Logging','Web-Performance','Web-Stat-Compression','Web-Dyn-Compression',
            'Web-Security','Web-Filtering','Web-App-Dev','Web-Net-Ext45','Web-Asp-Net45','Web-ISAPI-Ext','Web-ISAPI-Filter',
            'Web-WebSockets','Web-Mgmt-Tools','Web-Mgmt-Console'
$pendientes = Get-WindowsFeature $features | Where-Object { -not $_.Installed } | Select-Object -ExpandProperty Name
if ($pendientes) {
    Write-Host "   instalando: $($pendientes -join ', ')"
    $r = Install-WindowsFeature -Name $pendientes -IncludeManagementTools
    if ($r.RestartNeeded -eq 'Yes') { $reinicio = $true }
    Write-Ok "features instaladas (Success=$($r.Success))"
} else { Write-Ok "todas las features ya estaban instaladas" }

# ---------- 4.2 .NET Framework 4.8 ----------
Write-Paso "4.2 .NET Framework 4.8"
$ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
if ($ndp.Release -ge 528040) { Write-Ok ".NET $($ndp.Version) ya instalado" }
elseif ($SkipDotNet48) { Write-Falta ".NET 4.8 omitido por -SkipDotNet48" }
else {
    $exe = Get-Instalador 'ndp48*.exe' 'https://go.microsoft.com/fwlink/?linkid=2088631'
    Write-Host "   ejecutando instalador silencioso (varios minutos)"
    $p = Start-Process $exe -ArgumentList '/q /norestart' -Wait -PassThru
    Write-Host "   codigo de salida: $($p.ExitCode)  (0 ok, 3010 ok con reinicio pendiente)"
    if ($p.ExitCode -in 0, 3010) { $reinicio = $true; Write-Ok ".NET 4.8 instalado, requiere reinicio" }
    else { Write-Warning "El instalador de .NET 4.8 devolvio $($p.ExitCode)" }
}

# ---------- 4.3 VC++ 2015-2022 x64 ----------
Write-Paso "4.3 Visual C++ 2015-2022 Redistributable x64"
$vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -match 'Visual C\+\+ 2015-2022 Redistributable \(x64\)' }
if ($vc) { Write-Ok "$($vc[0].DisplayName) $($vc[0].DisplayVersion) ya instalado" }
elseif ($SkipVcRedist) { Write-Falta "VC++ omitido por -SkipVcRedist" }
else {
    $exe = Get-Instalador 'vc_redist*.x64.exe' 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    $p = Start-Process $exe -ArgumentList '/install /quiet /norestart' -Wait -PassThru
    Write-Host "   codigo de salida: $($p.ExitCode)"
    if ($p.ExitCode -eq 3010) { $reinicio = $true }
    if ($p.ExitCode -in 0, 3010) { Write-Ok "VC++ instalado" } else { Write-Warning "vc_redist devolvio $($p.ExitCode)" }
}

# ---------- 4.4 URL Rewrite 2.1 ----------
Write-Paso "4.4 URL Rewrite 2.1 (opcional para SPB)"
$rw = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\URL Rewrite' -ErrorAction SilentlyContinue
if ($rw) { Write-Ok "URL Rewrite $($rw.Version) ya instalado" }
elseif ($SkipUrlRewrite) { Write-Falta "URL Rewrite omitido por -SkipUrlRewrite" }
else {
    $msi = Get-Instalador 'rewrite_amd64*.msi' 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi'
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    Write-Host "   codigo de salida: $($p.ExitCode)"
    if ($p.ExitCode -in 0, 3010) { Write-Ok "URL Rewrite instalado" } else { Write-Warning "msiexec devolvio $($p.ExitCode)" }
}

# ---------- 4.5 win-acme ----------
Write-Paso "4.5 win-acme 2.2.9 en C:\wacs (no se ejecuta todavia)"
if (Test-Path 'C:\wacs\wacs.exe') { Write-Ok "ya existe C:\wacs\wacs.exe" }
elseif ($SkipWinAcme) { Write-Falta "win-acme omitido por -SkipWinAcme" }
else {
    $zip = Get-Instalador 'win-acme*.x64.pluggable.zip' 'https://github.com/win-acme/win-acme/releases/download/v2.2.9.1701/win-acme.v2.2.9.1701.x64.pluggable.zip'
    New-Item -ItemType Directory -Force 'C:\wacs' | Out-Null
    Expand-Archive -Path $zip -DestinationPath 'C:\wacs' -Force
    if (Test-Path 'C:\wacs\wacs.exe') { Write-Ok "win-acme descomprimido en C:\wacs" } else { Write-Warning "no se encontro wacs.exe tras descomprimir" }
}

# ---------- Re-registro de ASP.NET (solo si IIS existia antes que .NET 4.8) ----------
Write-Paso "Re-registro de ASP.NET 4.x en IIS"
$regiis = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\aspnet_regiis.exe"
if (Test-Path $regiis) {
    $o = & $regiis -iru 2>&1
    if ($o -match 'not supported') { Write-Host "   aspnet_regiis -iru no aplica en Server 2019; el registro lo hace Web-Asp-Net45" }
    else { Write-Ok "aspnet_regiis -iru ejecutado" }
}

Write-Paso "Resultado"
Stop-Log
Write-Host "Log: $log"
if ($reinicio) {
    Write-Warning "Hay cambios que requieren REINICIAR el servidor antes de desplegar SPB."
    if (Confirm-Accion "Reiniciar el servidor ahora?") { Restart-Computer -Force }
    else { Write-Host "Reinicia manualmente cuando puedas y luego ejecuta 02-Desplegar-SPB.ps1." }
} else {
    Write-Host "Sin reinicio pendiente. Siguiente paso: 02-Desplegar-SPB.ps1" -ForegroundColor Green
}
