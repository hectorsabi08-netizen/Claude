# SPB: instalación en el servidor destino (Windows Server 2019 + SQL Server 2019)

> **Para Claude en el servidor DESTINO.** Este documento es autocontenido: describe qué es SPB, qué necesita, cómo verificar lo que ya está instalado, cómo instalar lo que falte y cómo dejar el sitio funcionando. Sigue las fases en orden. Antes de cada acción que cambie el sistema, di en una línea qué vas a hacer. Pide confirmación explícita antes de reiniciar el servidor, tocar SQL Server o cambiar DNS.
>
> Alcance: **solo SPB**. Las demás apps del servidor origen (bots .NET Core, wallet-backend, widget) se migran después y NO forman parte de este documento.
>
> Los `Web.config` contienen contraseñas y API keys. **No las pegues en el chat ni en archivos de notas.**

---

## 1. Qué es SPB

| | |
|---|---|
| Tipo | Aplicación **ASP.NET WebForms** sobre **.NET Framework 4.8** (`compilation targetFramework="4.8"`, `httpRuntime targetFramework="4.6"`), compilador Roslyn incluido en `bin\roslyn`. |
| Origen | Servidor 54.236.39.192 (Windows Server 2025, IIS 10), ruta `C:\htdocs_apps\SPB`, 685 MB, sitio público `https://sbp.bintec.io`. |
| Base de datos | SQL Server, base **`SBP`**, login SQL **`sbp_admin`**. Hoy vive en `44.213.233.21:1433`. **Ver sección 5: hay que decidir si la base ya está en este servidor.** |
| Componentes de terceros | Todos vienen dentro de `bin\` (no requieren instaladores): DevExpress **v21.1.7** (Web, XtraReports, Xpo, Spreadsheet, RichEdit…), Entity Framework 6, GemBox.Spreadsheet, Magick.NET Q8 con nativos `Magick.Native-Q8-x64.dll`, SkiaSharp + HarfBuzzSharp con nativos en `x64\`, `x86\`, `arm64\` y `bin\`, itextsharp, AWSSDK S3/Lambda, Newtonsoft.Json, BouncyCastle. |
| Requisitos de SO | .NET Framework **4.8**, IIS con **ASP.NET 4.x**, **Visual C++ 2015-2022 Redistributable x64** (para los nativos de Magick/Skia), pool **64-bit** (no habilitar 32-bit). |
| Escritura en disco | `C:\UploadTemp\documentos\` (documentos subidos por usuarios; clave `PathUploadControl`), `SPB\UploadImages\`, `SPB\UploadTemp\`, `SPB\App_Data\UploadTemp\`. |
| Servicios externos | AWS S3 bucket `bintec-sbp` (us-east-2), Google Maps API, SQL Server. |
| Culture | `es-HN` fijada en web.config; el SO no necesita configuración regional especial. |

## 2. Paquete que llega desde el origen

Archivos generados en el origen en `C:\htdocs_apps\BK\migracion-2026-09\`:

| Archivo | Contenido | Destino donde descomprimir |
|---|---|---|
| `SPB-app.zip` | carpeta `SPB\` completa (aplicación, `Web.config` de producción, `bin`) | `C:\htdocs_apps\` → queda `C:\htdocs_apps\SPB\` |
| `SPB-documentos.zip` | carpeta `documentos\` (1.015 archivos, 732 MB) | `C:\UploadTemp\` → queda `C:\UploadTemp\documentos\` |
| `MIGRACION-SPB-IIS.md` | inventario completo del origen (referencia) | donde convenga |

Verificar integridad con `Get-FileHash -Algorithm SHA256` contra los hashes que acompañan al paquete. Mantener **las mismas rutas** (`C:\htdocs_apps\SPB`, `C:\UploadTemp\documentos`) para no tener que editar rutas en `Web.config`.

---

## 3. Fase 0: verificar qué hay en este servidor

Ejecutar en PowerShell **como administrador** y reportar el resultado completo antes de instalar nada:

```powershell
# SO
(Get-CimInstance Win32_OperatingSystem).Caption; [Environment]::OSVersion.Version
# .NET Framework: Release >= 528040 significa 4.8
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' | Select-Object Version,Release
# Roles IIS instalados
Get-WindowsFeature Web-* | Where-Object Installed | Select-Object -ExpandProperty Name
# ASP.NET 4.x registrado en IIS
Get-WindowsFeature Web-Asp-Net45,Web-Net-Ext45,Web-ISAPI-Ext,Web-ISAPI-Filter | Select-Object Name,Installed
# VC++ 2015-2022 x64
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Visual C\+\+ 2015-2022 Redistributable \(x64\)' } | Select-Object DisplayName,DisplayVersion
# SQL Server local
Get-Service MSSQL* | Select-Object Name,Status,StartType
# Puertos ya ocupados (IIS usará 80/443)
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 80,443,1433 } | Select-Object LocalAddress,LocalPort,OwningProcess
# Disco
Get-PSDrive C | Select-Object @{n='FreeGB';e={[math]::Round($_.Free/1GB,1)}}
# Memoria total y max server memory de SQL (ver sección 8)
[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)
```

Se necesitan al menos **3 GB libres** en C: para el paquete descomprimido más los zips.

---

## 4. Fase 1: instalar lo que falte

Instalar solo lo que la Fase 0 mostró como ausente. Windows Server 2019 no trae `winget`; usar descargas directas de Microsoft.

### 4.1 Roles de IIS necesarios para SPB

```powershell
Install-WindowsFeature Web-Server,Web-Common-Http,Web-Default-Doc,Web-Dir-Browsing,Web-Http-Errors,Web-Static-Content,Web-Health,Web-Http-Logging,Web-Performance,Web-Stat-Compression,Web-Dyn-Compression,Web-Security,Web-Filtering,Web-App-Dev,Web-Net-Ext45,Web-Asp-Net45,Web-ISAPI-Ext,Web-ISAPI-Filter,Web-WebSockets,Web-Mgmt-Tools,Web-Mgmt-Console -IncludeManagementTools
```

Los imprescindibles son `Web-Asp-Net45`, `Web-Net-Ext45`, `Web-ISAPI-Ext`, `Web-ISAPI-Filter`, `Web-Static-Content`, `Web-Default-Doc`. El resto replica el origen.

### 4.2 .NET Framework 4.8 (Server 2019 trae 4.7.2)

```powershell
$dl = "$env:TEMP\ndp48.exe"
Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2088631" -OutFile $dl -UseBasicParsing
Start-Process $dl -ArgumentList "/q /norestart" -Wait
```

Requiere **reinicio** (pedir confirmación). Después del reinicio, si IIS ya estaba instalado antes del framework, re-registrar ASP.NET:

```powershell
& "$env:windir\Microsoft.NET\Framework64\v4.0.30319\aspnet_regiis.exe" -iru
```

Si `aspnet_regiis -iru` falla con "This option is not supported on this version of the operating system", ignorarlo: en Server 2019 el registro se hace con `Install-WindowsFeature Web-Asp-Net45` (4.1).

### 4.3 Visual C++ 2015-2022 Redistributable x64

```powershell
$dl = "$env:TEMP\vc_redist.x64.exe"
Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $dl -UseBasicParsing
Start-Process $dl -ArgumentList "/install /quiet /norestart" -Wait
```

### 4.4 URL Rewrite 2.1 (opcional para SPB, obligatorio para las apps que vienen después)

```powershell
$dl = "$env:TEMP\rewrite_amd64.msi"
Invoke-WebRequest -Uri "https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi" -OutFile $dl -UseBasicParsing
Start-Process msiexec.exe -ArgumentList "/i `"$dl`" /qn /norestart" -Wait
```

### 4.5 win-acme (certificado Let's Encrypt para `sbp.bintec.io`)

Descargar la versión **2.2.9** x64 pluggable desde `https://github.com/win-acme/win-acme/releases` y descomprimir en `C:\wacs\`. No ejecutar todavía (Fase 6).

### 4.6 Si `Invoke-WebRequest` falla por TLS

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
```

Y si el servidor no tiene salida a Internet, descargar los instaladores desde otra máquina y copiarlos.

---

## 5. Fase 2: base de datos (decisión obligatoria)

SPB usa estas cadenas en `C:\htdocs_apps\SPB\Web.config`:

| Clave | Sección | Valor actual (sin contraseña) |
|---|---|---|
| `SqlServer` | `appSettings` | `Server=44.213.233.21;Database=SBP;User Id=sbp_admin;Password=…` |
| `localhost_SBP_Connection` | `connectionStrings` | `XpoProvider=MSSqlServer;data source=44.213.233.21;user id=sbp_admin;password=…;initial catalog=SBP;Persist Security Info=true` |
| `SqlServer2` | `appSettings` | `Server=localhost;Database=BintecSmartBot;User Id=igs_app;Password=…` (en el origen no había SQL local: probablemente sin uso) |

Comprobar en este servidor:

```powershell
sqlcmd -S localhost -E -Q "SELECT name FROM sys.databases WHERE name IN ('SBP','BintecSmartBot'); SELECT name FROM sys.sql_logins WHERE name IN ('sbp_admin','igs_app');"
# Si la instancia es nombrada: -S localhost\NOMBRE
Test-NetConnection 44.213.233.21 -Port 1433 | Select-Object TcpTestSucceeded
```

Preguntar al usuario y actuar según el caso:

| Caso | Acción en `Web.config` |
|---|---|
| **A.** Este servidor ES 44.213.233.21 o ya tiene la base `SBP` con el login `sbp_admin` | Cambiar en `SqlServer` y `localhost_SBP_Connection` el host `44.213.233.21` por `localhost` (o `localhost\INSTANCIA`). Mantener usuario y contraseña. |
| **B.** La base sigue en 44.213.233.21 | No tocar las cadenas. Confirmar que `Test-NetConnection` a 1433 devuelve `True` desde aquí y que el firewall de 44.213.233.21 permite la IP de este servidor. |
| **C.** Hay que restaurar la base aquí | Fuera del alcance de este documento; pedir al usuario el `.bak`, restaurarlo, crear el login `sbp_admin` con la misma contraseña y mapearlo a `db_owner` en `SBP`, y luego aplicar el caso A. |

Sea el caso que sea, SQL Server debe tener **autenticación mixta** habilitada (SPB usa login SQL, no Windows) y **TCP/IP** habilitado. Cambiar el modo de autenticación requiere reiniciar el servicio SQL: pedir confirmación.

Sobre `SqlServer2`: si no existe la base `BintecSmartBot` aquí, dejar la clave como está (queda inservible igual que en el origen) y anotarlo en el reporte final. No inventar una base.

---

## 6. Fase 3: desplegar la aplicación

```powershell
# 1. Descomprimir manteniendo rutas
New-Item -ItemType Directory -Force C:\htdocs_apps, C:\UploadTemp | Out-Null
Expand-Archive -Path <ruta>\SPB-app.zip        -DestinationPath C:\htdocs_apps -Force
Expand-Archive -Path <ruta>\SPB-documentos.zip -DestinationPath C:\UploadTemp  -Force
Test-Path C:\htdocs_apps\SPB\Web.config; Test-Path C:\htdocs_apps\SPB\bin\Operaciones.dll; Test-Path C:\UploadTemp\documentos

# 2. Quitar el bloqueo "descargado de Internet" si los archivos vinieron por navegador
Get-ChildItem C:\htdocs_apps\SPB -Recurse | Unblock-File

# 3. Pool de aplicación (64-bit, .NET 4.0 integrado, siempre activo)
Import-Module WebAdministration
New-WebAppPool -Name "SPB"
Set-ItemProperty IIS:\AppPools\SPB -Name managedRuntimeVersion -Value "v4.0"
Set-ItemProperty IIS:\AppPools\SPB -Name managedPipelineMode  -Value "Integrated"
Set-ItemProperty IIS:\AppPools\SPB -Name enable32BitAppOnWin64 -Value $false
Set-ItemProperty IIS:\AppPools\SPB -Name startMode -Value "AlwaysRunning"
Set-ItemProperty IIS:\AppPools\SPB -Name processModel.idleTimeout -Value ([TimeSpan]::FromMinutes(0))
Set-ItemProperty IIS:\AppPools\SPB -Name processModel.identityType -Value "ApplicationPoolIdentity"

# 4. Sitio. Binding HTTP con host header para producción y otro sin host para pruebas internas por IP
New-Website -Name "SPB" -PhysicalPath "C:\htdocs_apps\SPB" -ApplicationPool "SPB" -Port 80 -HostHeader "sbp.bintec.io"
New-WebBinding -Name "SPB" -Protocol http -Port 8080          # solo para pruebas; quitar al final
Set-ItemProperty "IIS:\Sites\SPB" -Name applicationDefaults.preloadEnabled -Value $true

# 5. Permisos de escritura para la identidad del pool
$acct = "IIS AppPool\SPB"
foreach ($p in "C:\UploadTemp\documentos","C:\htdocs_apps\SPB\UploadImages","C:\htdocs_apps\SPB\UploadTemp","C:\htdocs_apps\SPB\App_Data") {
  New-Item -ItemType Directory -Force $p | Out-Null
  icacls $p /grant "${acct}:(OI)(CI)M" /T /C | Out-Null
}
icacls C:\htdocs_apps\SPB /grant "${acct}:(OI)(CI)RX" /T /C | Out-Null

# 6. Si el Default Web Site ocupa *:80 sin host header, no hay conflicto (SPB usa host header). Si molesta, detenerlo:
# Stop-Website "Default Web Site"

Start-WebAppPool SPB; Start-Website SPB
```

Ajustes en `C:\htdocs_apps\SPB\Web.config` (hacer copia previa `Web.config.origen`):

1. Cadenas de conexión según la decisión de la sección 5.
2. `<customErrors mode="Off" />` → `<customErrors mode="RemoteOnly" />` **después** de que las pruebas pasen (mientras se prueba, `Off` ayuda a ver el error real).
3. Nada más. `PathUploadControl`, límites de request, handlers DevExpress y `es-HN` ya vienen correctos.

---

## 7. Fase 4: pruebas

```powershell
# Desde el propio servidor
Invoke-WebRequest http://localhost:8080/login.aspx -UseBasicParsing | Select-Object StatusCode
Invoke-WebRequest http://localhost:8080/default.aspx -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue | Select-Object StatusCode
```

Desde una PC del usuario, con `hosts` apuntando `sbp.bintec.io` a la IP de este servidor (o usando `http://<IP>:8080`), probar en el navegador:

- [ ] `login.aspx` carga con estilos DevExpress (tema Metropolis). Si carga sin CSS, revisar que `Web-Static-Content` esté instalado y los handlers `DX.ashx`/`DXR.axd` respondan 200.
- [ ] Iniciar sesión (valida la conexión a SQL).
- [ ] Abrir un reporte y exportarlo a **PDF** y a **Excel** (valida DevExpress Printing, GemBox, SkiaSharp/Magick nativos → VC++ redist).
- [ ] Subir un documento en un mantenimiento que use `PathUploadControl` y verificar que aparece en `C:\UploadTemp\documentos\<usuario>\`.
- [ ] Subir una imagen (UploadImages).
- [ ] Una pantalla con mapa (Google Maps). Si el mapa no carga, la API key tiene restricción por referrer/IP: hay que agregar el nuevo host en Google Cloud Console (lo hace el usuario).
- [ ] Una operación que use S3 (adjuntos). Si falla, verificar salida a `s3.us-east-2.amazonaws.com:443`.

Dónde mirar si algo falla:

| Síntoma | Revisar |
|---|---|
| 500.19 / 500.21 | ASP.NET 4.x no registrado en IIS → `Install-WindowsFeature Web-Asp-Net45`, `aspnet_regiis -iru` |
| "Could not load file or assembly ... Magick.Native / libSkiaSharp" o `BadImageFormatException` | Pool en 32-bit (debe ser 64) o falta VC++ redist x64 |
| Error de login a SQL "Login failed for user 'sbp_admin'" | Autenticación mixta deshabilitada o login inexistente (sección 5) |
| Timeout a SQL | Puerto 1433 cerrado hacia 44.213.233.21 o TCP/IP deshabilitado en la instancia local |
| Acceso denegado al subir archivos | `icacls` de la sección 6 paso 5 |
| Página en blanco / sin estilos | Handlers DevExpress bloqueados por `requestFiltering` (ya está `maxAllowedContentLength` alto; revisar `fileExtensions` `.axd`, `.ashx` permitidas) |
| Eventos | Event Viewer → Windows Logs → Application (origen ASP.NET 4.0.30319.0) y `C:\inetpub\logs\LogFiles\W3SVC<id>` |

---

## 8. Fase 5: convivencia con SQL Server (mismo servidor)

IIS y SQL Server compiten por memoria. Fijar el límite de SQL para dejar al menos 4 GB al SO + IIS (SPB con DevExpress puede usar 1 a 2 GB bajo carga de reportes):

```sql
-- Ejemplo para un servidor de 16 GB: SQL se queda con 10 GB
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'max server memory (MB)', 10240; RECONFIGURE;
```

Pedir confirmación antes de ejecutarlo y adaptar el número a la RAM real (Fase 0).

Firewall de Windows en el destino:

```powershell
New-NetFirewallRule -DisplayName "IIS HTTP 80"   -Direction Inbound -Protocol TCP -LocalPort 80  -Action Allow
New-NetFirewallRule -DisplayName "IIS HTTPS 443" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow
# 8080 solo mientras duren las pruebas; borrar la regla al terminar
```

**No abrir 1433 a Internet.** Si el servidor está en AWS, replicar 80/443 en el Security Group.

---

## 9. Fase 6: HTTPS y corte de DNS

1. Cuando las pruebas por IP pasen, el usuario cambia el registro **A** de `sbp.bintec.io` (hoy 54.236.39.192) a la IP pública de este servidor. Recomendar bajar el TTL a 300 s un día antes.
2. Con el DNS ya apuntando aquí, emitir el certificado con win-acme (validación HTTP-01, IIS debe responder en el puerto 80 con el host `sbp.bintec.io`):
   ```powershell
   C:\wacs\wacs.exe --source iis --siteid <id del sitio SPB> --host sbp.bintec.io --store certificatestore --certificatestore WebHosting --installation iis --accepttos --emailaddress <correo del usuario>
   ```
   win-acme crea el binding `https *:443 sbp.bintec.io` (SNI) y la tarea programada de renovación.
   Alternativa: en el origen existe una renovación wildcard `*.bintec.io` vía acme-dns (`C:\ProgramData\win-acme\acme-dns\auth.acme-dns.io\bintec.io.json`). Si el usuario copia esa carpeta, se puede reutilizar sin depender del DNS. Ambas opciones valen; la HTTP-01 es más simple.
3. Verificar `netsh http show sslcert` y abrir `https://sbp.bintec.io` desde fuera.
4. Opcional: redirigir HTTP→HTTPS con una regla de URL Rewrite (4.4) o con `<httpRedirect>`. El origen no lo tenía; no es obligatorio.
5. Quitar el binding de pruebas `:8080` y su regla de firewall. Cambiar `customErrors` a `RemoteOnly`.

Rollback: mientras el origen siga encendido, volver el DNS a 54.236.39.192 lo revierte todo. Si en el destino ya se subieron documentos nuevos, copiar `C:\UploadTemp\documentos` de vuelta antes.

---

## 10. Reporte final que debe entregar Claude en el destino

- Resultado de la Fase 0 (qué había y qué se instaló, con versiones).
- Decisión tomada en la sección 5 y valor final de las cadenas de conexión (host e instancia, **sin contraseña**).
- Nombre del sitio, pool, bindings y ruta física finales (`appcmd list site "SPB" /config`).
- Checklist de pruebas de la sección 7 con resultado de cada ítem.
- Pendientes que quedan para el usuario: cambio DNS, restricción de Google Maps key, Security Group, rotación de secretos que viajaron en texto plano, migración de las otras apps.
