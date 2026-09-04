# Informe final: migración de SPB a EC2AMAZ-FUREVU4

Fecha de corte: 2026-09-03. Sitio en producción: https://sbp.bintec.io (3.136.146.205, IP estática).

## 1. Servidor destino (Fase 0) y lo instalado (Fase 1)

| Componente | Estado inicial | Acción |
|---|---|---|
| Windows Server 2019 Datacenter, 8 GB RAM, 44 GB libres | OK | ninguna |
| .NET Framework 4.8 (Release 528049) | ya instalado | ninguna |
| Visual C++ 2015-2022 x64 14.44 | ya instalado | ninguna |
| IIS: Web-Asp-Net45, Web-Net-Ext45, Web-ISAPI-Ext, Web-ISAPI-Filter, Web-Dyn-Compression, Web-App-Dev, Web-WebSockets | faltaban | instaladas, sin reinicio |
| URL Rewrite 2.1 | no | instalado |
| win-acme 2.2.9.1701 | no | instalado en C:\wacs |
| SQL Server 2019 (MSSQLSERVER), autenticación mixta | ya instalado | max server memory 2048 -> 4096 MB |

## 2. Base de datos (decisión sección 5 del runbook)

- Este servidor NO es 44.213.233.21. Se decidió consolidar la base aquí: **caso A**.
- Web.config: `SqlServer` y `localhost_SBP_Connection` apuntan a `localhost`. `SqlServer2` (BintecSmartBot) se dejó como estaba; esa base no existe, igual que en el origen.
- Login `sbp_admin` creado en el SQL local y vinculado al usuario de la base (huérfano tras la restauración). db_owner.
- Backup final `SBP_corte.bak` tomado en el origen el 2026-09-03 19:25 (hora origen) con el sitio detenido, restaurado a las 18:33 hora local. 55 tablas, 45.089 filas, **idéntico fila por fila a 44.213.233.21** en el momento del corte.
- Copias de seguridad de la base local previa: `C:\SQLBackups\SBP_local_antes_20260902-1236.bak` y `-1237.bak`.

## 3. Sitio IIS final

```
Sitio:    SPB (id 2), ruta C:\htdocs_apps\SPB, preloadEnabled
Pool:     SPB, v4.0 Integrated, 64-bit, AlwaysRunning, idleTimeout 0, ApplicationPoolIdentity
Bindings: http  *:80:sbp.bintec.io
          https *:443:sbp.bintec.io (SNI, Let's Encrypt, renovación automática por win-acme)
Docs:     C:\UploadTemp\documentos (1015 archivos), permisos Modify para IIS AppPool\SPB
customErrors: RemoteOnly
```

DNS: registro A `sbp` en SmarterASP.NET -> 3.136.146.205, TTL 300 s. Verificado en 8.8.8.8.

## 4. Checklist de pruebas (sección 7 del runbook)

| Prueba | Resultado |
|---|---|
| login.aspx responde 200 (local y por host header) | OK |
| Handler DevExpress DXR.axd responde 200 | OK |
| login.aspx carga desde Internet por IP:8080 | OK (antes del corte) |
| Sin errores ASP.NET en Event Log | OK |
| Permisos de escritura en documentos, UploadImages, UploadTemp, App_Data | OK |
| Iniciar sesión con usuario real | pendiente de confirmar por el usuario |
| Exportar reporte a PDF y Excel | pendiente de confirmar |
| Subir documento / imagen | pendiente de confirmar |
| Mapa de Google | pendiente de confirmar (revisar restricción de API key) |
| Adjuntos S3 | pendiente de confirmar |
| https://sbp.bintec.io desde Internet | pendiente de confirmar |

## 5. Pendientes del usuario

1. Security Group: eliminar la regla TCP 8080 (ya no hay binding). Mantener 80 y 443. Nunca abrir 1433.
2. Google Maps: agregar sbp.bintec.io / 3.136.146.205 a las restricciones de la API key si las tiene.
3. Rotar los secretos que viajaron en texto plano en el paquete (contraseña de sbp_admin, claves AWS S3, API key de Google).
4. Mantener el origen (54.236.39.192 y la base en 44.213.233.21) encendido unos días como rollback; después apagar el sitio SPB allí de forma definitiva.
5. El wildcard *.bintec.io del otro servidor no se ve afectado; su renovación sigue allá.
6. Migración de las otras apps del origen (bots .NET Core, wallet-backend, widget): fuera de este alcance.

## 6. Rollback

Mientras el origen siga encendido: volver el registro A a 54.236.39.192 (5 minutos por el TTL) y arrancar el sitio SPB en el origen. Los datos escritos aquí después del corte habría que llevarlos al 44 con un .bak de esta base.
