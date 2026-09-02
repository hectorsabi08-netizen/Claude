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
. "$PSScriptRoot\_comun.ps1"
Assert-Admin
$ErrorActionPreference = 'Continue'
$report = Join-Path (Get-InventarioDir) ("fase0-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
$faltan = @()

$out = New-Object System.Text.StringBuilder
function R([string] $s) { [void]$out.AppendLine($s); Write-Host $s }

R "== FASE 0: verificacion del servidor destino  ($(Get-Date))"
R "Host: $env:COMPUTERNAME"

R "`n-- Sistema operativo"
R ((Get-CimInstance Win32_OperatingSystem).Caption + "  build " + [Environment]::OSVersion.Version)
R ("RAM total GB: " + [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1))
$freeGB = [math]::Round((Get-PSDrive C).Free/1GB,1)
R "Disco C: libre GB: $freeGB"
if ($freeGB -lt 3) { $faltan += "Menos de 3 GB libres en C: ($freeGB GB)" }

R "`n-- .NET Framework (Release >= 528040 es 4.8)"
$ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
R ("Version: {0}  Release: {1}" -f $ndp.Version, $ndp.Release)
if (-not $ndp -or $ndp.Release -lt 528040) { $faltan += ".NET Framework 4.8 (instalar con 01-Instalar-Prerrequisitos.ps1, requiere reinicio)" }

R "`n-- Roles IIS instalados"
$web = Get-WindowsFeature Web-* | Where-Object Installed | Select-Object -ExpandProperty Name
R ($(if ($web) { $web -join ', ' } else { '(ninguno: IIS no esta instalado)' }))
$req = 'Web-Asp-Net45','Web-Net-Ext45','Web-ISAPI-Ext','Web-ISAPI-Filter','Web-Static-Content','Web-Default-Doc'
foreach ($f in $req) {
    $inst = (Get-WindowsFeature $f).Installed
    R ("   {0,-20} {1}" -f $f, $(if ($inst) {'instalado'} else {'FALTA'}))
    if (-not $inst) { $faltan += "Feature IIS $f" }
}

R "`n-- Visual C++ 2015-2022 Redistributable x64"
$vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -match 'Visual C\+\+ 2015-2022 Redistributable \(x64\)' } | Select-Object -First 1
if ($vc) { R ("{0} {1}" -f $vc.DisplayName, $vc.DisplayVersion) } else { R "FALTA"; $faltan += "VC++ 2015-2022 x64" }

R "`n-- URL Rewrite"
$rw = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\URL Rewrite' -ErrorAction SilentlyContinue
R ($(if ($rw) { "Version $($rw.Version)" } else { "no instalado (opcional para SPB)" }))

R "`n-- SQL Server local"
$sql = Get-Service MSSQL* -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType
if ($sql) { $sql | ForEach-Object { R ("   {0,-25} {1,-10} {2}" -f $_.Name, $_.Status, $_.StartType) } } else { R "   (sin instancia local)" }
$sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
if ($sqlcmd -and $sql) {
    R "   Bases y logins relevantes (localhost):"
    $q = "SET NOCOUNT ON; SELECT 'DB: '+name FROM sys.databases WHERE name IN ('SBP','BintecSmartBot'); SELECT 'LOGIN: '+name FROM sys.sql_logins WHERE name IN ('sbp_admin','igs_app'); SELECT 'AUTH_MODE: '+CASE SERVERPROPERTY('IsIntegratedSecurityOnly') WHEN 1 THEN 'Solo Windows (hay que pasar a mixta)' ELSE 'Mixta' END;"
    $r = & sqlcmd -S localhost -E -h -1 -W -Q $q 2>&1
    $r | ForEach-Object { R "   $_" }
}
R "   Conectividad al SQL actual 44.213.233.21:1433:"
$t = Test-NetConnection 44.213.233.21 -Port 1433 -WarningAction SilentlyContinue
R "   TcpTestSucceeded = $($t.TcpTestSucceeded)"

R "`n-- Puertos 80/443/1433/8080 en escucha"
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 80,443,1433,8080 } |
    ForEach-Object {
        $proc = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        R ("   {0}:{1}  pid {2} ({3})" -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess, $proc)
    }

R "`n-- IIS: sitios y pools existentes"
if (Get-Module -ListAvailable WebAdministration) {
    Import-Module WebAdministration
    Get-Website | ForEach-Object { R ("   Sitio {0,-25} {1,-9} {2}" -f $_.Name, $_.State, (($_.bindings.Collection | ForEach-Object { $_.bindingInformation }) -join ' | ')) }
    Get-ChildItem IIS:\AppPools | ForEach-Object { R ("   Pool  {0,-25} {1,-9} {2} 32bit={3}" -f $_.Name, $_.State, $_.managedRuntimeVersion, $_.enable32BitAppOnWin64) }
    if (Get-Website SPB -ErrorAction SilentlyContinue) { R "   AVISO: ya existe un sitio SPB en este servidor." }
} else { R "   (modulo WebAdministration no disponible)" }

R "`n-- Rutas destino"
foreach ($p in 'C:\htdocs_apps\SPB\Web.config','C:\htdocs_apps\SPB\bin\Operaciones.dll','C:\UploadTemp\documentos','C:\wacs\wacs.exe') {
    R ("   {0,-45} {1}" -f $p, $(if (Test-Path $p) {'existe'} else {'no existe'}))
}

R "`n-- Contenido del backup: $BackupRoot"
if (Test-Path $BackupRoot) {
    Get-ChildItem $BackupRoot -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
        R ("   {0,12:N0} KB  {1}" -f ($_.Length/1KB), $_.FullName.Substring($BackupRoot.Length).TrimStart('\'))
    }
    foreach ($z in 'SPB-app.zip','SPB-documentos.zip','MIGRACION-SPB-IIS.md') {
        $f = Find-BackupFile $BackupRoot $z
        if ($f) { R "   encontrado $z -> $($f.FullName)" } else { R "   NO encontrado $z"; if ($z -like '*.zip') { $faltan += "$z en el backup" } }
    }
    $hashFile = Get-ChildItem $BackupRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'sha256|hash' } | Select-Object -First 1
    if ($hashFile) {
        R "   Archivo de hashes: $($hashFile.FullName)"
        Get-Content $hashFile.FullName | ForEach-Object {
            # Acepta formato sha256sum ("HASH  archivo"), Get-FileHash en tabla o CSV
            if ($_ -match '([0-9A-Fa-f]{64})' -and $_ -match '([^\s\\/*"]+\.(zip|md|txt))') {
                $expected = [regex]::Match($_, '[0-9A-Fa-f]{64}').Value
                $name     = [regex]::Match($_, '[^\s\\/*"]+\.(zip|md|txt)').Value
                $target = Find-BackupFile $BackupRoot $name
                if ($target) {
                    $actual = (Get-FileHash $target.FullName -Algorithm SHA256).Hash
                    R ("   hash {0,-22} {1}" -f $name, $(if ($actual -ieq $expected) {'OK'} else {'NO COINCIDE'}))
                    if ($actual -ine $expected) { $faltan += "Hash SHA256 de $name no coincide" }
                }
            }
        }
    } else { R "   (sin archivo de hashes SHA256; verificar a mano con Get-FileHash)" }
} else { R "   NO EXISTE la carpeta de backup"; $faltan += "Carpeta de backup $BackupRoot" }

R "`n== RESUMEN"
if ($faltan.Count -eq 0) { R "Todo listo para desplegar (01 si hace falta instalar algo, luego 02)." }
else { R "Pendiente antes de desplegar:"; $faltan | ForEach-Object { R "   - $_" } }

$out.ToString() | Out-File $report -Encoding UTF8
Write-Host "`nReporte guardado en: $report" -ForegroundColor Green
Write-Host "Sube ese archivo al repositorio (git add inventario; git commit; git push) para que Claude lo revise."
