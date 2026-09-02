<#
.SYNOPSIS
    Restaura un .bak de SBP (traido de 44.213.233.21) en el SQL Server local, alinea el login
    sbp_admin y vincula los usuarios huerfanos. Sirve para ensayar hoy y para el corte final.

.DESCRIPTION
    1. Lee la cabecera del .bak (base, fecha, archivos logicos).
    2. Pide confirmacion: la base local SBP se REEMPLAZA por completo.
    3. Detiene el pool SPB, pone la base en SINGLE_USER, RESTORE ... WITH REPLACE, vuelve a MULTI_USER.
    4. Crea el login sbp_admin si no existe (pide la contraseña en pantalla, nunca queda en el historial)
       o la alinea si se pasa -ResetPassword. Vincula el usuario huerfano y lo hace db_owner.
    5. Verifica conectando con sbp_admin y arranca el pool SPB.

.EXAMPLE
    .\07-Restaurar-BD.ps1 -BakPath "C:\htdocs_apps\BK\SBP.bak"
    .\07-Restaurar-BD.ps1 -BakPath "C:\htdocs_apps\BK"            # usa el .bak mas reciente de la carpeta
    .\07-Restaurar-BD.ps1 -BakPath "..." -ResetPassword            # ademas cambia la contraseña del login
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BakPath,
    [string] $Database    = 'SBP',
    [string] $SqlInstance = 'localhost',
    [string] $Login       = 'sbp_admin',
    [string[]] $OtrosUsuarios = @('sbp_app'),
    [switch] $ResetPassword,
    [switch] $SkipPool
)
#region Funciones comunes
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Ejecutar PowerShell como Administrador." }
}
function Get-InventarioDir {
    $base = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }
    $dir  = Join-Path $base 'inventario'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; return $dir
}
function Start-Log([string] $Nombre) {
    $file = Join-Path (Get-InventarioDir) ("{0}-{1}-{2}.log" -f $Nombre, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
    try { Start-Transcript -Path $file -Append | Out-Null } catch {}
    return $file
}
function Stop-Log { try { Stop-Transcript | Out-Null } catch {} }
function Write-Paso([string] $Texto) { Write-Host "`n>> $Texto" -ForegroundColor Cyan }
function Write-Ok([string] $Texto)   { Write-Host "   OK  $Texto" -ForegroundColor Green }
function Confirm-Accion([string] $Texto) { $r = Read-Host "$Texto  Escribe SI para continuar"; return ($r -eq 'SI') }
#endregion

Assert-Admin
$ErrorActionPreference = 'Stop'
$log = Start-Log 'fase2-restaurar-bd'
Add-Type -AssemblyName System.Data

# ---------- .bak ----------
Write-Paso "Archivo de backup"
if (Test-Path $BakPath -PathType Container) {
    $bak = Get-ChildItem $BakPath -Filter *.bak -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $bak) { throw "No hay archivos .bak en $BakPath" }
    $BakPath = $bak.FullName
}
if (-not (Test-Path $BakPath)) { throw "No existe $BakPath" }
$bakInfo = Get-Item $BakPath
Write-Host ("   {0}  ({1:N0} MB, modificado {2})" -f $bakInfo.FullName, ($bakInfo.Length/1MB), $bakInfo.LastWriteTime)
$bakSql = $BakPath -replace "'", "''"

# ---------- conexion integrada ----------
function New-Conn([string] $Db = 'master', [string] $User, [string] $Pass) {
    $cs = if ($User) { "Server=$SqlInstance;Database=$Db;User ID=$User;Password=$Pass;Encrypt=False;Connect Timeout=15" }
          else       { "Server=$SqlInstance;Database=$Db;Integrated Security=True;Encrypt=False;Connect Timeout=15" }
    $c = New-Object System.Data.SqlClient.SqlConnection $cs; $c.Open(); return $c
}
function Invoke-Sql([System.Data.SqlClient.SqlConnection] $Conn, [string] $Sql, [int] $Timeout = 300) {
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd; $dt = New-Object System.Data.DataTable
    [void]$da.Fill($dt); return $dt
}
function Invoke-SqlNonQuery([System.Data.SqlClient.SqlConnection] $Conn, [string] $Sql, [int] $Timeout = 0) {
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout; [void]$cmd.ExecuteNonQuery()
}

$conn = New-Conn
Write-Paso "Contenido del .bak"
$hdr = Invoke-Sql $conn "RESTORE HEADERONLY FROM DISK = N'$bakSql'"
$h = $hdr.Rows[0]
Write-Host ("   base origen: {0}   tomado: {1}   servidor: {2}   tipo: {3}" -f $h.DatabaseName, $h.BackupFinishDate, $h.ServerName, $(if ($h.BackupType -eq 1) {'FULL'} else { "tipo $($h.BackupType) (se esperaba FULL)" }))
if ($h.BackupType -ne 1) { throw "El .bak no es un backup FULL." }
$files = Invoke-Sql $conn "RESTORE FILELISTONLY FROM DISK = N'$bakSql'"
$files | ForEach-Object { Write-Host ("   {0,-4} {1,-25} {2}" -f $_.Type, $_.LogicalName, $_.PhysicalName) }

# ---------- rutas destino ----------
$existe = (Invoke-Sql $conn "SELECT COUNT(*) AS n FROM sys.databases WHERE name = N'$Database'").Rows[0].n -gt 0
$dataPath = (Invoke-Sql $conn "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(500)) AS p").Rows[0].p
$logPath  = (Invoke-Sql $conn "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS nvarchar(500)) AS p").Rows[0].p
$actuales = @{}
if ($existe) {
    (Invoke-Sql $conn "SELECT name, physical_name FROM sys.master_files WHERE database_id = DB_ID(N'$Database')") |
        ForEach-Object { $actuales[$_.name] = $_.physical_name }
}
$moves = @()
foreach ($f in $files) {
    $dest = if ($actuales.ContainsKey($f.LogicalName)) { $actuales[$f.LogicalName] }
            else {
                $ext = if ($f.Type -eq 'L') { '.ldf' } else { '.mdf' }
                $dir = if ($f.Type -eq 'L') { $logPath } else { $dataPath }
                Join-Path $dir ("{0}_{1}{2}" -f $Database, $f.LogicalName, $ext)
            }
    $moves += "MOVE N'$($f.LogicalName)' TO N'$($dest -replace "'", "''")'"
}

Write-Paso "Confirmacion"
if ($existe) {
    $cnt = (Invoke-Sql $conn "SELECT COUNT(*) AS n FROM [$Database].sys.tables").Rows[0].n
    Write-Host "   La base local [$Database] EXISTE ($cnt tablas) y sera REEMPLAZADA por el backup del $($h.BackupFinishDate)."
} else { Write-Host "   La base [$Database] no existe; se creara desde el backup." }
if (-not (Confirm-Accion "Restaurar [$Database] en $SqlInstance desde $BakPath?")) { $conn.Close(); Stop-Log; return }

# ---------- restore ----------
if (-not $SkipPool -and (Get-Module -ListAvailable WebAdministration)) {
    Import-Module WebAdministration
    if (Test-Path IIS:\AppPools\SPB) { Stop-WebAppPool SPB -ErrorAction SilentlyContinue; Write-Ok "pool SPB detenido" }
}
Write-Paso "RESTORE DATABASE (puede tardar varios minutos)"
if ($existe) { Invoke-SqlNonQuery $conn "ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE" }
$restore = "RESTORE DATABASE [$Database] FROM DISK = N'$bakSql' WITH REPLACE, RECOVERY, CHECKSUM, STATS = 10, " + ($moves -join ', ')
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-SqlNonQuery $conn $restore
$sw.Stop()
Invoke-SqlNonQuery $conn "ALTER DATABASE [$Database] SET MULTI_USER"
$cnt = (Invoke-Sql $conn "SELECT COUNT(*) AS n FROM [$Database].sys.tables").Rows[0].n
Write-Ok ("restaurada en {0:N0} s, {1} tablas" -f $sw.Elapsed.TotalSeconds, $cnt)

# ---------- login y usuarios huerfanos ----------
Write-Paso "Login $Login y usuarios huerfanos"
$loginExiste = (Invoke-Sql $conn "SELECT COUNT(*) AS n FROM sys.sql_logins WHERE name = N'$Login'").Rows[0].n -gt 0
$plain = $null
if (-not $loginExiste -or $ResetPassword) {
    $sec = Read-Host -AsSecureString "Contraseña de $Login (la misma que tiene el Web.config)"
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    $pwSql = $plain -replace "'", "''"
    if ($loginExiste) { Invoke-SqlNonQuery $conn "ALTER LOGIN [$Login] WITH PASSWORD = N'$pwSql', CHECK_POLICY = OFF"; Write-Ok "contraseña de $Login actualizada" }
    else { Invoke-SqlNonQuery $conn "CREATE LOGIN [$Login] WITH PASSWORD = N'$pwSql', CHECK_POLICY = OFF, DEFAULT_DATABASE = [$Database]"; Write-Ok "login $Login creado" }
} else { Write-Host "   login $Login ya existe (usa -ResetPassword para cambiar la contraseña)" }
Invoke-SqlNonQuery $conn "ALTER LOGIN [$Login] ENABLE"

$dbConn = New-Conn $Database
foreach ($u in @($Login) + $OtrosUsuarios) {
    $userExiste  = (Invoke-Sql $dbConn "SELECT COUNT(*) AS n FROM sys.database_principals WHERE name = N'$u' AND type = 'S'").Rows[0].n -gt 0
    $loginExiste = (Invoke-Sql $conn   "SELECT COUNT(*) AS n FROM sys.sql_logins WHERE name = N'$u'").Rows[0].n -gt 0
    if ($userExiste -and $loginExiste) { Invoke-SqlNonQuery $dbConn "ALTER USER [$u] WITH LOGIN = [$u]"; Write-Ok "usuario $u vinculado a su login" }
    elseif ($userExiste) { Write-Host "   usuario $u existe en la base pero no hay login en el servidor; se deja huerfano (no lo usa SPB)" }
}
Invoke-SqlNonQuery $dbConn "IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id WHERE r.name = 'db_owner' AND m.name = N'$Login') ALTER ROLE db_owner ADD MEMBER [$Login]"
Write-Ok "$Login es db_owner de $Database"
$dbConn.Close(); $conn.Close()

# ---------- verificacion ----------
Write-Paso "Verificacion"
if ($plain) {
    try {
        $v = New-Conn $Database $Login $plain
        $r = (Invoke-Sql $v "SELECT SUSER_SNAME() AS login, DB_NAME() AS base, (SELECT COUNT(*) FROM sys.tables) AS tablas").Rows[0]
        $v.Close(); Write-Ok ("conectado como {0} a {1}, {2} tablas" -f $r.login, $r.base, $r.tablas)
    } catch { Write-Warning "La conexion con $Login fallo: $($_.Exception.Message)" }
    $plain = $null
} else {
    Write-Host "   Verifica a mano (pide la contraseña en pantalla):"
    Write-Host "   sqlcmd -S $SqlInstance -U $Login -d $Database -Q `"SELECT SUSER_SNAME(), DB_NAME(), (SELECT COUNT(*) FROM sys.tables)`""
}

if (-not $SkipPool -and (Get-Module -ListAvailable WebAdministration) -and (Test-Path IIS:\AppPools\SPB)) {
    Start-WebAppPool SPB; Write-Ok "pool SPB arrancado"
}
Stop-Log
Write-Host "`nLog: $log" -ForegroundColor Green
