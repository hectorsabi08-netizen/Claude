# Decisiones y estado de la migración SPB

Servidor destino: EC2AMAZ-FUREVU4, Windows Server 2019 Datacenter, IP pública 3.136.146.205.

| Fecha | Punto | Decisión / estado |
|---|---|---|
| 2026-09-02 | Fase 0 | Faltaban 4 features de IIS. .NET 4.8 y VC++ ya estaban. Hashes de los zips OK. |
| 2026-09-02 | Fase 1 | Features IIS, URL Rewrite 2.1 y win-acme 2.2.9 instalados. Sin reinicio. |
| 2026-09-02 | Fase 3 | SPB desplegado en C:\htdocs_apps\SPB, 1015 documentos en C:\UploadTemp\documentos. Pool y sitio SPB creados, bindings *:80 sbp.bintec.io y *:8080 (pruebas). |
| 2026-09-02 | Fase 2 | El servidor NO es 44.213.233.21 (la base de producción actual). SQL local tiene una copia restaurada de SBP con usuarios huérfanos (sbp_admin, sbp_app, igs_app). Web.config puesto en caso A (localhost). Copia en Web.config.origen. |
| 2026-09-02 | Login | sbp_admin no existía como login. Creado por 07-Restaurar-BD.ps1, vinculado al usuario huérfano, db_owner. Conexión verificada. |
| 2026-09-02 | BD | Copias de la base local previa: C:\SQLBackups\SBP_local_antes_20260902-1236.bak y ...-1237.bak (1.4 MB, verificadas). |
| 2026-09-02 | BD | Restaurado C:\SQLBackups\SBP.bak (FULL, origen EC2AMAZ-04L9MRN, 12:40 hora origen). 55 tablas, 44.886 filas. Comparación con 44.213.233.21 en vivo: idéntica. La copia local anterior tenía 8.296 filas. |
| 2026-09-02 | Fase 4 | login.aspx 200, DXR.axd 200, sin errores en Event Log, permisos OK. Pruebas de navegador pendientes. |
| 2026-09-02 | Fase 5 | Reglas firewall 80/443/8080 creadas. SQL max server memory 2048 -> 4096 MB. |

## Pendiente

- Pruebas desde el navegador (checklist del script 04).
- Security Group de AWS: 80/443 abiertos, 8080 solo para pruebas.
- Corte: detener uso en origen, BACKUP ... WITH COPY_ONLY, CHECKSUM en 44.213.233.21, copiar a C:\SQLBackups y ejecutar 07-Restaurar-BD.ps1 (el login ya existe; la comparación con el origen debe dar "sin diferencias").
- Cambio de DNS sbp.bintec.io (hoy 54.236.39.192) -> 3.136.146.205. Bajar TTL a 300 s un día antes.
- Fase 6: certificado HTTPS con win-acme, quitar binding 8080, customErrors RemoteOnly.
- Restricción de la API key de Google Maps al nuevo host/IP.
