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
. "$PSScriptRoot\_comun.ps1"
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
    if (Confirm-Accion "Ejecutar sp_configure 'max server memory' = $MaxServerMemoryMB en $SqlInstance?") {
        $q = "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)', $MaxServerMemoryMB; RECONFIGURE; EXEC sp_configure 'max server memory (MB)';"
        & sqlcmd -S $SqlInstance -E -Q $q
        Write-Ok "aplicado"
    } else { Write-Host "   cancelado por el usuario" }
}
