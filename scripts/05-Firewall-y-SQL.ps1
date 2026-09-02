<#
.SYNOPSIS
    FASE 5 del runbook SPB: reglas de firewall de Windows y limite de memoria de SQL Server local.
    El cambio en SQL pide confirmacion explicita.

.EXAMPLE
    .\05-Firewall-y-SQL.ps1                              # solo firewall 80/443 (+8080 pruebas)
    .\05-Firewall-y-SQL.ps1 -MaxServerMemoryMB 10240     # ademas fija max server memory en SQL local
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [int]    $PuertoPruebas = 8080,
    [int]    $MaxServerMemoryMB,
    [string] $SqlInstance = 'localhost'
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

Write-Paso "Firewall de Windows"
$reglas = @(
    @{ Name='IIS HTTP 80';   Port=80 },
    @{ Name='IIS HTTPS 443'; Port=443 },
    @{ Name="IIS pruebas $PuertoPruebas (temporal)"; Port=$PuertoPruebas }
)
foreach ($r in $reglas) {
    if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) { Write-Ok "$($r.Name) ya existe"; continue }
    if ($PSCmdlet.ShouldProcess($r.Name, 'New-NetFirewallRule')) {
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol TCP -LocalPort $r.Port -Action Allow | Out-Null
        Write-Ok "creada $($r.Name)"
    }
}
Write-Host "   NO se abre 1433. Si el servidor esta en AWS, replicar 80/443 en el Security Group."

if ($MaxServerMemoryMB) {
    Write-Paso "SQL Server: max server memory = $MaxServerMemoryMB MB en $SqlInstance"
    $ramMB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1MB)
    Write-Host "   RAM total: $ramMB MB. Quedan $($ramMB - $MaxServerMemoryMB) MB para SO + IIS (recomendado >= 4096)."
    if (($ramMB - $MaxServerMemoryMB) -lt 4096) { Write-Warning "Deja menos de 4 GB para SO + IIS." }
    if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { throw "sqlcmd no esta disponible." }
    if (Confirm-Accion "Ejecutar sp_configure 'max server memory' = $MaxServerMemoryMB en ${SqlInstance}?") {
        $q = "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)', $MaxServerMemoryMB; RECONFIGURE; EXEC sp_configure 'max server memory (MB)';"
        & sqlcmd -S $SqlInstance -E -Q $q
        Write-Ok "aplicado"
    } else { Write-Host "   cancelado por el usuario" }
}
