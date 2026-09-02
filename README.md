# Migración SPB: replicar el sitio IIS de "Server 54" en Windows Server 2019

Scripts PowerShell que implementan, fase por fase, el runbook
[`docs/SPB-INSTALAR-EN-DESTINO.md`](docs/SPB-INSTALAR-EN-DESTINO.md) para levantar
**SPB** (ASP.NET WebForms, .NET 4.8, DevExpress) en el servidor destino a partir del
paquete que está en:

```
C:\htdocs_apps\BK\migracion-2026-09\OneDrive_2026-09-02\Server 54
```

## Por qué scripts y no Claude directamente en el servidor

El instalador de **Claude Desktop** falla en ese servidor:

> Claude requires Windows 10 version 2004 or later (build 19041+). Current build: 17763.

El build 17763 es Windows Server 2019 y la app de escritorio no se instala ahí.
Además, Claude Code en la web (esta sesión) corre en un contenedor remoto y **no ve
el disco del servidor**, así que no puede ejecutar el runbook por sí mismo.

Opciones:

| Opción | Cómo |
|---|---|
| **Scripts de este repo** (recomendado ahora) | Clonar el repo en el servidor y ejecutar los scripts en orden. Cada uno deja un reporte en `inventario\` que se sube al repo para que Claude lo revise y ajuste el siguiente paso. |
| Claude Code CLI en el servidor | Instalar Node.js 18+ y Git for Windows, luego `npm install -g @anthropic-ai/claude-code` y ejecutar `claude` en la carpeta del repo. Con eso Claude sí lee el disco y puede seguir el runbook interactivamente. |
| Claude Desktop en otra PC | Windows 10 2004+ / Windows 11, trabajando contra el servidor por RDP o carpeta compartida. |

## Uso

En el servidor destino, **PowerShell como Administrador**:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
git clone https://github.com/hectorsabi08-netizen/Claude.git C:\htdocs_apps\migracion-spb
cd C:\htdocs_apps\migracion-spb\scripts
```

| Fase | Script | Qué hace | Cambia el sistema |
|---|---|---|---|
| 0 | `00-Verificar-Destino.ps1` | SO, .NET, roles IIS, VC++, SQL local, puertos, disco, contenido y hashes del backup. Reporte en `inventario\fase0-*.txt`. | No |
| 1 | `01-Instalar-Prerrequisitos.ps1` | Roles IIS, .NET 4.8, VC++ 2015-2022 x64, URL Rewrite, win-acme. Solo instala lo que falta. Pide confirmación antes de reiniciar. | Sí |
| 3 | `02-Desplegar-SPB.ps1` | Descomprime `SPB-app.zip` y `SPB-documentos.zip` (o copia carpetas), crea pool y sitio, permisos NTFS, binding 8080 de pruebas. Acepta `-WhatIf`. | Sí |
| 2 | `03-Configurar-WebConfig.ps1` | Diagnóstico SQL y cadenas de conexión. Con `-SqlHost localhost` aplica el caso A; sin parámetro es el caso B. Nunca muestra contraseñas. | Solo con `-SqlHost` |
| 4 | `04-Probar-SPB.ps1` | Peticiones HTTP locales, Event Log, permisos, checklist manual. Reporte en `inventario\fase4-*.txt`. | No |
| 5 | `05-Firewall-y-SQL.ps1` | Reglas 80/443 (+8080 temporal). Con `-MaxServerMemoryMB` fija memoria de SQL previa confirmación. | Sí |
| 6 | `06-HTTPS-y-Cierre.ps1` | win-acme HTTP-01 para `sbp.bintec.io`, quita binding 8080, `customErrors RemoteOnly`, opcional `-RedirigirHttps`. Ejecutar tras el cambio de DNS. | Sí |

Cada script es autónomo (no depende de otros archivos). Ejecute siempre el
**archivo** `.ps1` desde la carpeta `scripts`, por ejemplo `.\00-Verificar-Destino.ps1`.

Secuencia mínima:

```powershell
.\00-Verificar-Destino.ps1
.\01-Instalar-Prerrequisitos.ps1          # reiniciar si lo pide y volver a ejecutar 00
.\02-Desplegar-SPB.ps1 -WhatIf            # revisar
.\02-Desplegar-SPB.ps1
.\03-Configurar-WebConfig.ps1             # decidir caso A/B con lo que muestra
.\04-Probar-SPB.ps1
.\05-Firewall-y-SQL.ps1
# ... cambio de DNS por el usuario ...
.\06-HTTPS-y-Cierre.ps1 -Email <correo>
```

Después de las fases 0 y 4:

```powershell
cd C:\htdocs_apps\migracion-spb
git add inventario; git commit -m "Reporte fase X"; git push
```

y Claude revisa el reporte desde la web. `Web.config`, `.zip` y `.pfx` están en
`.gitignore` para que no se suban secretos ni paquetes.

## Rutas y nombres fijos (iguales al origen)

| | |
|---|---|
| Aplicación | `C:\htdocs_apps\SPB` |
| Documentos subidos | `C:\UploadTemp\documentos` |
| Pool / sitio IIS | `SPB` (64-bit, v4.0 Integrated, AlwaysRunning, ApplicationPoolIdentity) |
| Bindings | `http *:80 sbp.bintec.io`, `http *:8080` (pruebas), `https *:443 sbp.bintec.io` (fase 6) |
| win-acme | `C:\wacs` |

## Fuera del alcance de los scripts

- Restaurar la base `SBP` desde un `.bak` y crear el login `sbp_admin` (caso C del runbook).
- Cambio del registro DNS, Security Group de AWS, restricción de la API key de Google Maps.
- Las otras apps del origen (bots .NET Core, wallet-backend, widget).
