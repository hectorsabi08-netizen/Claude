<#
.SYNOPSIS
    Restaura un .bak de SBP (traido de 44.213.233.21) en el SQL Server local con salvaguardas:
    copia previa de la base local, verificacion del .bak, comparacion de datos y alineacion del login.

.DESCRIPTION
    A. Lee la cabecera del .bak (base, fecha, servidor) y lo verifica (RESTORE VERIFYONLY WITH CHECKSUM).
       Avisa si el backup tiene mas de -MaxHorasAntiguedad horas.
    B. Toma el conteo de filas por tabla de la base local actual (para comparar despues).
    C. Hace COPIA DE SEGURIDAD de la base local en -BackupLocalDir (SBP_local_antes_<fecha>.bak, COPY_ONLY).
    D. Pide confirmacion, detiene el pool SPB, SINGLE_USER, RESTORE ... WITH REPLACE, MULTI_USER.
    E. Crea el login sbp_admin si no existe (pide la contraseña en pantalla) o la alinea con -ResetPassword.
       Vincula usuarios huerfanos y da db_owner.
    F. Compara filas por tabla: local anterior vs restaurada, y restaurada vs ORIGEN EN VIVO (44.213.233.21),
       para confirmar que el .bak trae la ultima data. Guarda el detalle en inventario\comparacion-bd-<fecha>.csv.
    G. Verifica la conexion con sbp_admin y arranca el pool SPB.

.EXAMPLE
    .\07-Restaurar-BD.ps1 -BakPath "C:\SQLBackups\SBP.bak"
    .\07-Restaurar-BD.ps1 -BakPath "C:\SQLBackups\SBP.bak" -SoloValidar     # A, B y comparacion con origen; no restaura
    .\07-Restaurar-BD.ps1 -BakPath "C:\SQLBackups\SBP.bak" -ResetPassword
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BakPath,
    [string] $Database       = 'SBP',
    [string] $SqlInstance    = 'localhost',
    [string] $Login          = 'sbp_admin',
    [string[]] $OtrosUsuarios = @('sbp_app'),
    [string] $OrigenSql      = '44.213.233.21',
    [string] $BackupLocalDir,
    [int]    $MaxHorasAntiguedad = 24,
    [switch] $ResetPassword,
    [switch] $SoloValidar,
    [switch] $SkipBackupLocal,
    [switch] $SkipComparacionOrigen,
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
$ts = Get-Date -Format 'yyyyMMdd-HHmm'

# ---------- helpers SQL ----------
function New-Conn([string] $Server, [string] $Db = 'master', [string] $User, [string] $Pass) {
    $cs = if ($User) { "Server=$Server;Database=$Db;User ID=$User;Password=$Pass;Encrypt=False;Connect Timeout=20" }
          else       { "Server=$Server;Database=$Db;Integrated Security=True;Encrypt=False;Connect Timeout=20" }
    $c = New-Object System.Data.SqlClient.SqlConnection $cs; $c.Open(); return $c
}
function Invoke-Sql([System.Data.SqlClient.SqlConnection] $Conn, [string] $Sql, [int] $Timeout = 600) {
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd; $dt = New-Object System.Data.DataTable
    [void]$da.Fill($dt); return ,$dt
}
function Invoke-SqlNonQuery([System.Data.SqlClient.SqlConnection] $Conn, [string] $Sql, [int] $Timeout = 0) {
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout; [void]$cmd.ExecuteNonQuery()
}
$qFilas = @"
SELECT s.name + '.' + t.name AS tabla, SUM(p.row_count) AS filas
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.dm_db_partition_stats p ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY s.name, t.name
"@
function Get-Filas([System.Data.SqlClient.SqlConnection] $Conn) {
    $h = @{}; foreach ($r in (Invoke-Sql $Conn $qFilas).Rows) { $h[$r.tabla] = [long]$r.filas }; return $h
}
function Compare-Filas([hashtable] $A, [hashtable] $B, [string] $NombreA, [string] $NombreB, [string] $Csv) {
    $rows = @()
    foreach ($t in ($A.Keys + $B.Keys | Sort-Object -Unique)) {
        $fa = if ($A.ContainsKey($t)) { $A[$t] } else { $null }
        $fb = if ($B.ContainsKey($t)) { $B[$t] } else { $null }
        $rows += [pscustomobject]@{ tabla = $t; $NombreA = $fa; $NombreB = $fb; diferencia = $(if ($fa -ne $null -and $fb -ne $null) { $fb - $fa } else { 'solo en ' + $(if ($fa -ne $null) { $NombreA } else { $NombreB }) }) }
    }
    $rows | Export-Csv $Csv -NoTypeInformation -Encoding UTF8
    $difs = $rows | Where-Object { $_.diferencia -ne 0 }
    $totA = ($A.Values | Measure-Object -Sum).Sum; $totB = ($B.Values | Measure-Object -Sum).Sum
    Write-Host ("   tablas: {0} en {1}, {2} en {3}   filas totales: {4:N0} vs {5:N0}" -f $A.Count, $NombreA, $B.Count, $NombreB, $totA, $totB)
    if ($difs) {
        Write-Host "   tablas con diferencias ($($difs.Count)); las 15 mayores:"
        $difs | Sort-Object { if ($_.diferencia -is [long] -or $_.diferencia -is [int]) { [math]::Abs($_.diferencia) } else { [long]::MaxValue } } -Descending |
            Select-Object -First 15 | ForEach-Object { Write-Host ("      {0,-45} {1,12} -> {2,12}   ({3})" -f $_.tabla, $_.$NombreA, $_.$NombreB, $_.diferencia) }
    } else { Write-Host "   sin diferencias: $NombreA y $NombreB tienen exactamente las mismas filas por tabla" }
    Write-Host "   detalle: $Csv"
    return $difs
}

# ---------- A. .bak ----------
Write-Paso "A. Archivo de backup"
if (Test-Path $BakPath -PathType Container) {
    $bak = Get-ChildItem $BakPath -Filter *.bak -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $bak) { throw "No hay archivos .bak en $BakPath" }
    $BakPath = $bak.FullName
}
if (-not (Test-Path $BakPath)) { throw "No existe $BakPath" }
$bakInfo = Get-Item $BakPath
if (-not $BackupLocalDir) { $BackupLocalDir = $bakInfo.DirectoryName }
Write-Host ("   {0}  ({1:N0} MB, modificado {2})" -f $bakInfo.FullName, ($bakInfo.Length/1MB), $bakInfo.LastWriteTime)
$bakSql = $BakPath -replace "'", "''"

$conn = New-Conn $SqlInstance
$h = (Invoke-Sql $conn "RESTORE HEADERONLY FROM DISK = N'$bakSql'").Rows[0]
$tipo = switch ([int]$h.BackupType) { 1 {'FULL'} 2 {'LOG'} 5 {'DIFERENCIAL'} default {"tipo $($h.BackupType)"} }
$edad = (Get-Date) - [datetime]$h.BackupFinishDate
Write-Host ("   base: {0}   servidor origen: {1}   tipo: {2}" -f $h.DatabaseName, $h.ServerName, $tipo)
Write-Host ("   tomado: {0}   antiguedad: {1:N1} horas" -f $h.BackupFinishDate, $edad.TotalHours)
if ([int]$h.BackupType -ne 1) { throw "El .bak no es un backup FULL; no sirve para reemplazar la base." }
if ($h.DatabaseName -ne $Database) { Write-Warning "El .bak es de la base '$($h.DatabaseName)', no de '$Database'." }
if ($edad.TotalHours -gt $MaxHorasAntiguedad) { Write-Warning "El backup tiene mas de $MaxHorasAntiguedad horas. Si el origen sigue en uso, faltaran datos recientes." }
if ($edad.TotalHours -lt 0) { Write-Host "   (antiguedad negativa: el servidor origen esta en otra zona horaria; la fecha mostrada es la hora local del origen)" }
$conChecksum = [bool]$h.HasBackupChecksums
$chk = if ($conChecksum) { " WITH CHECKSUM" } else { "" }
Write-Host "   verificando integridad (RESTORE VERIFYONLY$chk)..."
Invoke-SqlNonQuery $conn "RESTORE VERIFYONLY FROM DISK = N'$bakSql'$chk"
if ($conChecksum) { Write-Ok "el .bak es legible y su checksum es correcto" }
else { Write-Ok "el .bak es legible (se tomo sin CHECKSUM; para el corte conviene usar WITH CHECKSUM en el BACKUP)" }
$files = Invoke-Sql $conn "RESTORE FILELISTONLY FROM DISK = N'$bakSql'"
$files.Rows | ForEach-Object { Write-Host ("   {0,-4} {1,-25} {2,10:N0} MB  {3}" -f $_.Type, $_.LogicalName, ($_.Size/1MB), $_.PhysicalName) }

# ---------- B. estado de la base local ----------
Write-Paso "B. Base local [$Database] actual"
$existe = [int](Invoke-Sql $conn "SELECT COUNT(*) AS n FROM sys.databases WHERE name = N'$Database'").Rows[0].n -gt 0
$filasAntes = @{}
if ($existe) {
    $dbConn = New-Conn $SqlInstance $Database
    $filasAntes = Get-Filas $dbConn; $dbConn.Close()
    $tam = (Invoke-Sql $conn "SELECT SUM(size)*8/1024 AS mb FROM sys.master_files WHERE database_id = DB_ID(N'$Database')").Rows[0].mb
    Write-Host ("   existe: {0} tablas, {1:N0} filas, {2:N0} MB en disco" -f $filasAntes.Count, ($filasAntes.Values | Measure-Object -Sum).Sum, $tam)
} else { Write-Host "   no existe; se creara desde el backup" }

# ---------- C. copia de seguridad de la local ----------
$copiaLocal = $null
if ($existe -and -not $SkipBackupLocal -and -not $SoloValidar) {
    Write-Paso "C. Copia de seguridad de la base local antes de tocarla"
    New-Item -ItemType Directory -Force $BackupLocalDir | Out-Null
    $copiaLocal = Join-Path $BackupLocalDir ("{0}_local_antes_{1}.bak" -f $Database, $ts)
    $libre = [math]::Round((Get-PSDrive ($BackupLocalDir.Substring(0,1))).Free/1MB)
    Write-Host "   destino: $copiaLocal   (libre en disco: $libre MB)"
    Invoke-SqlNonQuery $conn "BACKUP DATABASE [$Database] TO DISK = N'$($copiaLocal -replace "'", "''")' WITH COPY_ONLY, COMPRESSION, CHECKSUM, INIT, STATS = 25"
    Invoke-SqlNonQuery $conn "RESTORE VERIFYONLY FROM DISK = N'$($copiaLocal -replace "'", "''")' WITH CHECKSUM"
    Write-Ok ("copia guardada y verificada: {0:N0} MB" -f ((Get-Item $copiaLocal).Length/1MB))
} elseif ($existe -and $SkipBackupLocal) { Write-Warning "Se omite la copia de la base local por -SkipBackupLocal." }

# ---------- comparacion previa con origen (solo en -SoloValidar) ----------
$plain = $null
function Read-PasswordPlain([string] $Texto) {
    $sec = Read-Host -AsSecureString $Texto
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
function Get-FilasOrigen {
    if ($SkipComparacionOrigen) { return $null }
    $t = Test-NetConnection $OrigenSql -Port 1433 -WarningAction SilentlyContinue
    if (-not $t.TcpTestSucceeded) { Write-Warning "No se alcanza ${OrigenSql}:1433; se omite la comparacion con el origen."; return $null }
    if (-not $script:plain) { $script:plain = Read-PasswordPlain "Contraseña de $Login en el ORIGEN $OrigenSql (para comparar datos)" }
    try {
        $o = New-Conn $OrigenSql $Database $Login $script:plain
        $f = Get-Filas $o; $o.Close(); return $f
    } catch { Write-Warning "No se pudo consultar el origen: $($_.Exception.Message)"; return $null }
}

if ($SoloValidar) {
    Write-Paso "Solo validacion: comparar base local actual con el ORIGEN en vivo"
    $filasOrigen = Get-FilasOrigen
    if ($filasOrigen -and $existe) {
        [void](Compare-Filas $filasAntes $filasOrigen 'local_actual' 'origen_vivo' (Join-Path (Get-InventarioDir) "comparacion-bd-local-vs-origen-$ts.csv"))
        Write-Host "   (las diferencias son lo que la copia local NO tiene y el .bak deberia traer)"
    }
    $conn.Close(); Stop-Log; Write-Host "`nSin cambios. Log: $log" -ForegroundColor Green; return
}

# ---------- D. restore ----------
Write-Paso "D. Confirmacion"
if ($existe) { Write-Host "   [$Database] sera REEMPLAZADA por el backup del $($h.BackupFinishDate). Copia previa: $copiaLocal" }
if (-not (Confirm-Accion "Restaurar [$Database] en $SqlInstance desde ${BakPath}?")) { $conn.Close(); Stop-Log; return }

$actuales = @{}
if ($existe) { (Invoke-Sql $conn "SELECT name, physical_name FROM sys.master_files WHERE database_id = DB_ID(N'$Database')").Rows | ForEach-Object { $actuales[$_.name] = $_.physical_name } }
$dataPath = (Invoke-Sql $conn "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(500)) AS p").Rows[0].p
$logPath  = (Invoke-Sql $conn "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS nvarchar(500)) AS p").Rows[0].p
$moves = @()
foreach ($f in $files.Rows) {
    $dest = if ($actuales.ContainsKey($f.LogicalName)) { $actuales[$f.LogicalName] }
            else { Join-Path $(if ($f.Type -eq 'L') { $logPath } else { $dataPath }) ("{0}_{1}{2}" -f $Database, $f.LogicalName, $(if ($f.Type -eq 'L') {'.ldf'} else {'.mdf'})) }
    $moves += "MOVE N'$($f.LogicalName)' TO N'$($dest -replace "'", "''")'"
}
if (-not $SkipPool -and (Get-Module -ListAvailable WebAdministration)) {
    Import-Module WebAdministration
    if (Test-Path IIS:\AppPools\SPB) { Stop-WebAppPool SPB -ErrorAction SilentlyContinue; Write-Ok "pool SPB detenido" }
}
Write-Paso "RESTORE DATABASE (puede tardar varios minutos)"
if ($existe) { Invoke-SqlNonQuery $conn "ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE" }
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $chkRestore = if ($conChecksum) { "CHECKSUM, " } else { "" }
    Invoke-SqlNonQuery $conn ("RESTORE DATABASE [$Database] FROM DISK = N'$bakSql' WITH REPLACE, RECOVERY, ${chkRestore}STATS = 10, " + ($moves -join ', '))
} catch {
    if ($existe) { try { Invoke-SqlNonQuery $conn "ALTER DATABASE [$Database] SET MULTI_USER" } catch {} }
    throw "Fallo el RESTORE: $($_.Exception.Message). La base local sigue como estaba; copia previa en $copiaLocal"
}
$sw.Stop()
Invoke-SqlNonQuery $conn "ALTER DATABASE [$Database] SET MULTI_USER"
Write-Ok ("restaurada en {0:N0} s" -f $sw.Elapsed.TotalSeconds)

# ---------- E. login ----------
Write-Paso "E. Login $Login y usuarios huerfanos"
$loginExiste = [int](Invoke-Sql $conn "SELECT COUNT(*) AS n FROM sys.sql_logins WHERE name = N'$Login'").Rows[0].n -gt 0
if (-not $loginExiste -or $ResetPassword) {
    if (-not $plain) { $plain = Read-PasswordPlain "Contraseña de $Login (la misma del Web.config)" }
    $pwSql = $plain -replace "'", "''"
    if ($loginExiste) { Invoke-SqlNonQuery $conn "ALTER LOGIN [$Login] WITH PASSWORD = N'$pwSql', CHECK_POLICY = OFF"; Write-Ok "contraseña de $Login actualizada" }
    else { Invoke-SqlNonQuery $conn "CREATE LOGIN [$Login] WITH PASSWORD = N'$pwSql', CHECK_POLICY = OFF, DEFAULT_DATABASE = [$Database]"; Write-Ok "login $Login creado" }
} else { Write-Host "   login $Login ya existe (usa -ResetPassword para cambiar la contraseña)" }
Invoke-SqlNonQuery $conn "ALTER LOGIN [$Login] ENABLE"
$dbConn = New-Conn $SqlInstance $Database
foreach ($u in @($Login) + $OtrosUsuarios) {
    $userExiste = [int](Invoke-Sql $dbConn "SELECT COUNT(*) AS n FROM sys.database_principals WHERE name = N'$u' AND type = 'S'").Rows[0].n -gt 0
    $lgExiste   = [int](Invoke-Sql $conn   "SELECT COUNT(*) AS n FROM sys.sql_logins WHERE name = N'$u'").Rows[0].n -gt 0
    if ($userExiste -and $lgExiste) { Invoke-SqlNonQuery $dbConn "ALTER USER [$u] WITH LOGIN = [$u]"; Write-Ok "usuario $u vinculado a su login" }
    elseif ($userExiste) { Write-Host "   usuario $u existe en la base pero no hay login en el servidor; se deja (no lo usa SPB)" }
}
Invoke-SqlNonQuery $dbConn "IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id WHERE r.name = 'db_owner' AND m.name = N'$Login') ALTER ROLE db_owner ADD MEMBER [$Login]"
Write-Ok "$Login es db_owner de $Database"

# ---------- F. comparaciones ----------
Write-Paso "F. Comparacion de datos"
$filasDespues = Get-Filas $dbConn; $dbConn.Close()
if ($existe) {
    Write-Host "   1) copia local anterior  vs  base restaurada del .bak"
    $d1 = Compare-Filas $filasAntes $filasDespues 'local_anterior' 'restaurada' (Join-Path (Get-InventarioDir) "comparacion-bd-anterior-vs-restaurada-$ts.csv")
}
$filasOrigen = Get-FilasOrigen
if ($filasOrigen) {
    Write-Host "   2) base restaurada  vs  ORIGEN EN VIVO ($OrigenSql)"
    $d2 = Compare-Filas $filasDespues $filasOrigen 'restaurada' 'origen_vivo' (Join-Path (Get-InventarioDir) "comparacion-bd-restaurada-vs-origen-$ts.csv")
    if (-not $d2) { Write-Ok "el .bak contiene exactamente la misma data que el origen en este momento" }
    else { Write-Warning "El origen tiene filas que el .bak no trae: se siguio usando despues de tomar el backup. El dia del corte hay que detener el origen, sacar un .bak nuevo y repetir este script." }
}

# ---------- G. verificacion ----------
Write-Paso "G. Verificacion de conexion como $Login"
if (-not $plain) { $plain = Read-PasswordPlain "Contraseña de $Login para verificar la conexion local" }
try {
    $v = New-Conn $SqlInstance $Database $Login $plain
    $r = (Invoke-Sql $v "SELECT SUSER_SNAME() AS login, DB_NAME() AS base, (SELECT COUNT(*) FROM sys.tables) AS tablas").Rows[0]
    $v.Close(); Write-Ok ("conectado como {0} a {1}, {2} tablas" -f $r.login, $r.base, $r.tablas)
} catch { Write-Warning "La conexion con $Login fallo: $($_.Exception.Message). Ejecuta de nuevo con -ResetPassword." }
$plain = $null
$conn.Close()
if (-not $SkipPool -and (Get-Module -ListAvailable WebAdministration) -and (Test-Path IIS:\AppPools\SPB)) { Start-WebAppPool SPB; Write-Ok "pool SPB arrancado" }
Stop-Log
Write-Host "`nCopia previa de la base local: $copiaLocal" -ForegroundColor Yellow
Write-Host "Log: $log" -ForegroundColor Green
