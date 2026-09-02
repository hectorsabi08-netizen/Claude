<#
.SYNOPSIS
    Descarga la ultima version de los scripts desde GitHub (sin necesidad de Git) y
    reemplaza la carpeta scripts\ y docs\ de este repositorio local.
    No toca inventario\ ni ningun otro archivo.

.EXAMPLE
    .\Actualizar.ps1
#>
[CmdletBinding()]
param(
    [string] $Rama = 'claude/replicar-server-iis-moaebx',
    [string] $Repo = 'hectorsabi08-netizen/Claude'
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$raiz = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { Split-Path (Get-Location).Path -Parent }
$zip  = Join-Path $env:TEMP 'migracion-spb.zip'
$tmp  = Join-Path $env:TEMP 'migracion-spb-extract'
$url  = "https://github.com/$Repo/archive/refs/heads/$Rama.zip"

Write-Host "Descargando $url"
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$origen = Get-ChildItem $tmp -Directory | Select-Object -First 1

foreach ($carpeta in 'scripts', 'docs') {
    $src = Join-Path $origen.FullName $carpeta
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path $raiz $carpeta
    New-Item -ItemType Directory -Force $dst | Out-Null
    Get-ChildItem $src -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $dst $_.Name) -Force
        Write-Host "   actualizado $carpeta\$($_.Name)"
    }
}
Copy-Item (Join-Path $origen.FullName 'README.md') (Join-Path $raiz 'README.md') -Force
Get-ChildItem $raiz -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nScripts actualizados en $raiz" -ForegroundColor Green
