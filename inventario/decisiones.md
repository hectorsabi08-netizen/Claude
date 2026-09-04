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

| 2026-09-02 | Uso | GenLog: último login 2026-08-29 (J.Navarro). Últimos 30 días: solo 2 usuarios activos (J.Navarro, d.hernandez), 2-12 eventos/día, nada desde el 29/08. El corte puede hacerse en horario laboral avisando a esos dos usuarios. |
| 2026-09-02 | Pruebas | localhost:8080/login.aspx carga el formulario. Desde fuera no carga: falta abrir puertos en el Security Group de AWS. |

| 2026-09-02 | Decisión | Confirmado por el usuario: SPB en este servidor usa la base LOCAL (caso A). La base del 44 solo se vuelve a copiar el día del corte. |

| 2026-09-03 | Corte | Puntos 1-3 hechos (aviso a usuarios, sitio origen detenido, .bak final). IP 3.136.146.205 confirmada estática. DNS en SmarterASP.NET, TTL ya en 300 s. |
| 2026-09-03 | Corte | SBP_corte.bak (tomado 19:25 hora origen) restaurado a las 18:33. 55 tablas, 45.089 filas, idéntico al origen en vivo. Login sbp_admin OK. Pool SPB arrancado. |

## Plan de corte propuesto

1. Abrir 80 y 443 en el Security Group (antes, para probar por hosts).
2. Pruebas desde navegador con hosts -> 3.136.146.205 (checklist del script 04).
3. Un día antes: bajar TTL del registro A de sbp.bintec.io a 300 s.
4. Día del corte: avisar a J.Navarro y d.hernandez; detener el sitio en el origen (54.236.39.192);
   BACKUP DATABASE SBP ... WITH COPY_ONLY, CHECKSUM en 44.213.233.21; copiar a C:\SQLBackups;
   .\07-Restaurar-BD.ps1 -BakPath ... -SkipBackupLocal (la comparación con el origen debe dar "sin diferencias").
5. Cambiar el registro A a 3.136.146.205.
6. .\06-HTTPS-y-Cierre.ps1 -Email <correo> (win-acme HTTP-01, quita 8080, customErrors RemoteOnly).
7. Verificar https://sbp.bintec.io desde fuera; restringir la API key de Google Maps al nuevo host/IP.
8. Rollback: volver el DNS a 54.236.39.192 mientras el origen siga encendido.

## Pendiente

- Pruebas desde el navegador (checklist del script 04).
- Security Group de AWS: 80/443 abiertos, 8080 solo para pruebas.
- Corte: detener uso en origen, BACKUP ... WITH COPY_ONLY, CHECKSUM en 44.213.233.21, copiar a C:\SQLBackups y ejecutar 07-Restaurar-BD.ps1 (el login ya existe; la comparación con el origen debe dar "sin diferencias").
- Cambio de DNS sbp.bintec.io (hoy 54.236.39.192) -> 3.136.146.205. Bajar TTL a 300 s un día antes.
- Fase 6: certificado HTTPS con win-acme, quitar binding 8080, customErrors RemoteOnly.
- Restricción de la API key de Google Maps al nuevo host/IP.
