<#
.SYNOPSIS
    FASE 0 del runbook SPB: verifica que hay en este servidor y que contiene el backup.
    No cambia nada. Genera inventario\fase0-<host>-<fecha>.txt para subir al repositorio.

.EXAMPLE
    .\00-Verificar-Destino.ps1 -BackupRoot "C:\htdocs_apps\BK\migracion-2026-09\OneDrive_2026-09-02\Server 54"
#>
[CmdletBinding()]
param(
    [string] $BackupRoot = "C:\htdocs_apps\BK\migracion-2026-09\OneDrive_2026-09-02\Server 54"
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
$report = Join-Path (Get-InventarioDir) ("fase0-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
$faltan = @()

$out = New-Object System.Text.StringBuilder
function Write-Rep([string] $s) { [void]$out.AppendLine($s); Write-Host $s }

Write-Rep "== FASE 0: verificacion del servidor destino  ($(Get-Date))"
Write-Rep "Host: $env:COMPUTERNAME"

Write-Rep "`n-- Sistema operativo"
Write-Rep ((Get-CimInstance Win32_OperatingSystem).Caption + "  build " + [Environment]::OSVersion.Version)
Write-Rep ("RAM total GB: " + [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1))
$freeGB = [math]::Round((Get-PSDrive C).Free/1GB,1)
Write-Rep "Disco C: libre GB: $freeGB"
if ($freeGB -lt 3) { $faltan += "Menos de 3 GB libres en C: ($freeGB GB)" }

Write-Rep "`n-- .NET Framework (Release >= 528040 es 4.8)"
$ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
Write-Rep ("Version: {0}  Release: {1}" -f $ndp.Version, $ndp.Release)
if (-not $ndp -or $ndp.Release -lt 528040) { $faltan += ".NET Framework 4.8 (instalar con 01-Instalar-Prerrequisitos.ps1, requiere reinicio)" }

Write-Rep "`n-- Roles IIS instalados"
$web = Get-WindowsFeature Web-* | Where-Object Installed | Select-Object -ExpandProperty Name
Write-Rep ($(if ($web) { $web -join ', ' } else { '(ninguno: IIS no esta instalado)' }))
$req = 'Web-Asp-Net45','Web-Net-Ext45','Web-ISAPI-Ext','Web-ISAPI-Filter','Web-Static-Content','Web-Default-Doc'
foreach ($f in $req) {
    $inst = (Get-WindowsFeature $f).Installed
    Write-Rep ("   {0,-20} {1}" -f $f, $(if ($inst) {'instalado'} else {'FALTA'}))
    if (-not $inst) { $faltan += "Feature IIS $f" }
}

Write-Rep "`n-- Visual C++ 2015-2022 Redistributable x64"
$vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -match 'Visual C\+\+ 2015-2022 Redistributable \(x64\)' } | Select-Object -First 1
if ($vc) { Write-Rep ("{0} {1}" -f $vc.DisplayName, $vc.DisplayVersion) } else { Write-Rep "FALTA"; $faltan += "VC++ 2015-2022 x64" }

Write-Rep "`n-- URL Rewrite"
$rw = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\URL Rewrite' -ErrorAction SilentlyContinue
Write-Rep ($(if ($rw) { "Version $($rw.Version)" } else { "no instalado (opcional para SPB)" }))

Write-Rep "`n-- SQL Server local"
$sql = Get-Service MSSQL* -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType
if ($sql) { $sql | ForEach-Object { Write-Rep ("   {0,-25} {1,-10} {2}" -f $_.Name, $_.Status, $_.StartType) } } else { Write-Rep "   (sin instancia local)" }
$sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
if ($sqlcmd -and $sql) {
    Write-Rep "   Bases y logins relevantes (localhost):"
    $q = "SET NOCOUNT ON; SELECT 'DB: '+name FROM sys.databases WHERE name IN ('SBP','BintecSmartBot'); SELECT 'LOGIN: '+name FROM sys.sql_logins WHERE name IN ('sbp_admin','igs_app'); SELECT 'AUTH_MODE: '+CASE SERVERPROPERTY('IsIntegratedSecurityOnly') WHEN 1 THEN 'Solo Windows (hay que pasar a mixta)' ELSE 'Mixta' END;"
    $r = & sqlcmd -S localhost -E -h -1 -W -Q $q 2>&1
    $r | ForEach-Object { Write-Rep "   $_" }
}
Write-Rep "   Conectividad al SQL actual 44.213.233.21:1433:"
$t = Test-NetConnection 44.213.233.21 -Port 1433 -WarningAction SilentlyContinue
Write-Rep "   TcpTestSucceeded = $($t.TcpTestSucceeded)"

Write-Rep "`n-- Puertos 80/443/1433/8080 en escucha"
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 80,443,1433,8080 } |
    ForEach-Object {
        $proc = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Write-Rep ("   {0}:{1}  pid {2} ({3})" -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess, $proc)
    }

Write-Rep "`n-- IIS: sitios y pools existentes"
if (Get-Module -ListAvailable WebAdministration) {
    Import-Module WebAdministration
    Get-Website | ForEach-Object { Write-Rep ("   Sitio {0,-25} {1,-9} {2}" -f $_.Name, $_.State, (($_.bindings.Collection | ForEach-Object { $_.bindingInformation }) -join ' | ')) }
    Get-ChildItem IIS:\AppPools | ForEach-Object { Write-Rep ("   Pool  {0,-25} {1,-9} {2} 32bit={3}" -f $_.Name, $_.State, $_.managedRuntimeVersion, $_.enable32BitAppOnWin64) }
    if (Get-Website SPB -ErrorAction SilentlyContinue) { Write-Rep "   AVISO: ya existe un sitio SPB en este servidor." }
} else { Write-Rep "   (modulo WebAdministration no disponible)" }

Write-Rep "`n-- Rutas destino"
foreach ($p in 'C:\htdocs_apps\SPB\Web.config','C:\htdocs_apps\SPB\bin\Operaciones.dll','C:\UploadTemp\documentos','C:\wacs\wacs.exe') {
    Write-Rep ("   {0,-45} {1}" -f $p, $(if (Test-Path $p) {'existe'} else {'no existe'}))
}

Write-Rep "`n-- Contenido del backup: $BackupRoot"
if (Test-Path $BackupRoot) {
    Get-ChildItem $BackupRoot -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
        Write-Rep ("   {0,12:N0} KB  {1}" -f ($_.Length/1KB), $_.FullName.Substring($BackupRoot.Length).TrimStart('\'))
    }
    foreach ($z in 'SPB-app.zip','SPB-documentos.zip','MIGRACION-SPB-IIS.md') {
        $f = Find-BackupFile $BackupRoot $z
        if ($f) { Write-Rep "   encontrado $z -> $($f.FullName)" } else { Write-Rep "   NO encontrado $z"; if ($z -like '*.zip') { $faltan += "$z en el backup" } }
    }
    $hashFile = Get-ChildItem $BackupRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'sha256|hash' } | Select-Object -First 1
    if ($hashFile) {
        Write-Rep "   Archivo de hashes: $($hashFile.FullName)"
        if ($hashFile.Length -eq 0) { Write-Rep "   AVISO: el archivo de hashes esta vacio; no se puede verificar la integridad de los zip." }
        Get-Content $hashFile.FullName | ForEach-Object {
            # Acepta formato sha256sum ("HASH  archivo"), Get-FileHash en tabla o CSV
            if ($_ -match '([0-9A-Fa-f]{64})' -and $_ -match '([^\s\\/*"]+\.(zip|md|txt))') {
                $expected = [regex]::Match($_, '[0-9A-Fa-f]{64}').Value
                $name     = [regex]::Match($_, '[^\s\\/*"]+\.(zip|md|txt)').Value
                $target = Find-BackupFile $BackupRoot $name
                if ($target) {
                    $actual = (Get-FileHash $target.FullName -Algorithm SHA256).Hash
                    Write-Rep ("   hash {0,-22} {1}" -f $name, $(if ($actual -ieq $expected) {'OK'} else {'NO COINCIDE'}))
                    if ($actual -ine $expected) { $faltan += "Hash SHA256 de $name no coincide" }
                }
            }
        }
    } else { Write-Rep "   (sin archivo de hashes SHA256; verificar a mano con Get-FileHash)" }
} else { Write-Rep "   NO EXISTE la carpeta de backup"; $faltan += "Carpeta de backup $BackupRoot" }

Write-Rep "`n== RESUMEN"
if ($faltan.Count -eq 0) { Write-Rep "Todo listo para desplegar (01 si hace falta instalar algo, luego 02)." }
else { Write-Rep "Pendiente antes de desplegar:"; $faltan | ForEach-Object { Write-Rep "   - $_" } }

$out.ToString() | Out-File $report -Encoding UTF8
Write-Host "`nReporte guardado en: $report" -ForegroundColor Green
Write-Host "Sube ese archivo al repositorio (git add inventario; git commit; git push) para que Claude lo revise."
