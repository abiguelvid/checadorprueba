# Checador de empleados

Tablero, kiosko y administración del registro de asistencia de Nanofactor. Los datos viven en el proyecto de Supabase `pjicnaamvuluommctphb`. **No hace falta pegar nada en otro proyecto.**

Estas páginas son HTML estático (GitHub Pages):

| Página | Archivo | Para qué |
| --- | --- | --- |
| Tablero | `external-check-in-dashboard.html` | Ver asistencia, mapa y CSV |
| Admin | `admin-empleados.html` | Registros con mapa, altas y bajas |
| Kiosko | `kiosk-check-in.html` | Entrada, salida y comida, con ubicación obligatoria. Entrada y salida además piden foto |
| Vacaciones | `vacaciones.html` | Solicitar vacaciones con PIN, o aprobar las del equipo |

Cuando este fork publique GitHub Pages, las rutas quedan así:

- https://abiguelvid.github.io/checadorprueba/external-check-in-dashboard.html
- https://abiguelvid.github.io/checadorprueba/admin-empleados.html
- https://abiguelvid.github.io/checadorprueba/kiosk-check-in.html

Hay que fusionar el cambio a `main` antes de que Pages lo sirva. El tablero enlaza a Admin y a Kiosko.

Esas páginas cargan `checador.js?v=…`. La `v` es el inicio del SHA-256 de ese archivo. GitHub Pages puede guardar el JS anterior unos minutos. Si el HTML nuevo siguiera pidiendo `checador.js` sin versión, el navegador usaría el JS viejo y fallarían funciones nuevas. Al cambiar `checador.js` hay que poner la huella nueva en el kiosko, la admin, vacaciones y el tablero. La prueba lo exige.

## SQL

En el proyecto ya se corrieron `sql/01_ubicacion_kiosk_attendance.sql` y `sql/02_seed_empleados.sql`. **No hace falta volver a correrlos.**

Para la foto y la bitácora hay que correr, en el SQL Editor y en este orden:

1. `sql/04_foto_kiosk_attendance.sql` — columna `photo_path`, bucket privado `attendance-photos` y políticas. Léelo antes. No usa ni pide la service role.
2. `sql/06_bitacora_auditoria.sql` — huella SHA-256 de cada foto, bitácora que solo crece, y la verificación de la cadena.
3. `sql/07_politica_insert_foto.sql` — corrige la política de subida.
4. `sql/08_comida_kiosk_attendance.sql` — habilita salida a comer y regreso. Entrada y salida siguen funcionando si este archivo todavía no se corre; los botones de comida avisan y no registran.
5. `sql/05_retencion_fotos_asistencia.sql` — opcional. Solo crea funciones para listar fotos de más de 90 días y, después, limpiar la ruta. **No borra archivos y no queda programado.** El cron de ejemplo está comentado.
6. `sql/09_ubicacion_obligatoria.sql` — todavía no se corre. Rechaza checadas **nuevas** sin lat/lng válidos, vengan de esta página o de otro cliente. No rellena ni borra las que ya están sin ubicación, y esas filas viejas se pueden seguir actualizando.
7. `sql/10_festivos_y_vacaciones.sql` — festivos de toda la empresa, el manager de cada persona y las vacaciones con dos aprobaciones. Sin este archivo el kiosko sigue checando igual. No cambia la ubicación obligatoria del paso 9.

**No corras el paso 3** mientras el kiosko y la admin tengan que seguir con la llave anon y el esquema actual. `sql/03_seguridad_pin_y_admin.sql` queda para más adelante. Si algún día se corre, su `register_attendance` ya pide la foto y la huella.

Nadie aplicó estos archivos desde el cambio de la foto. Quedan en el repo para que los revise quien administra Supabase.

Los PIN asignados no se republican en este documento. Están en la base y se consultan desde la admin.

## Kiosko

`kiosk-check-in.html` sigue pidiendo el PIN igual que antes. Al pulsar cualquier botón pide primero la ubicación. Entrada y salida, solo si esa ubicación es válida, piden la foto.

- La cámara es la frontal (`facingMode: user`). Hay vista previa, se toma la foto y se puede repetir.
- Sin foto no hay checada. Si niegan el permiso, no hay cámara o falla, sale un mensaje en español y **no se escribe el registro**.
- La foto se comprime a JPEG de máximo 640 px de ancho y se sube al bucket privado `attendance-photos`, en `empleado/fecha/archivo.jpg`. La ruta queda en `photo_path`.
- Antes de la primera foto de ese navegador aparece un aviso. El texto se edita en `AVISO_FOTO`, dentro de `checador.js`. Si lo cambias, sube `AVISO_FOTO_VERSION` para que el kiosco lo vuelva a mostrar.
- La ubicación es obligatoria en entrada, salida, salida a comer y regreso. Se pide al abrir y otra vez al marcar, antes de la foto y antes de guardar. Si el permiso está denegado, el GPS no responde, pasa el tiempo de espera o el navegador no tiene geolocalización, **no se guarda nada** y la pantalla dice cómo activarlo, con un botón Reintentar.
- Un doble clic, o la misma acción repetida en menos de un minuto, no crea otro renglón. Una salida justo después de una entrada sí se guarda.
- Hasta que se corra el SQL 9, otro cliente todavía puede insertar sin coordenadas. Ese archivo, cuando se corre, también rechaza esos insert nuevos. El aparato de Nanofactor tiene que abrir esta página.
- La foto guarda también su huella SHA-256 en `photo_sha256`.
- Publica la página cuando quieras: entrada y salida siguen igual si el SQL 8 no se ha corrido. La comida pide ese archivo antes de usarse.

## Página de admin

1. Abre `admin-empleados.html`.
2. Escribe el código de acceso (`nfg-rh` hasta que lo cambies) y pulsa **Entrar**.
3. **Registros:** elige empleado (o Todos) y una fecha en hora de Ciudad de México. Cada renglón muestra fecha y hora de CDMX, empleado, Entrada o Salida, un enlace a Google Maps, **Ver foto** e **Historial**. La foto se abre con una URL firmada de 60 segundos. Si no hubo coordenadas, dice `sin ubicación`. Si el registro es viejo o vino de otro cliente, dice `sin foto`.
4. **Verificar integridad** recorre la cadena de la bitácora y contrasta la huella de las fotos de esa lista. El último hash conviene copiarlo fuera de Supabase.
5. Para agregar: nombre, PIN de 4 dígitos o **Generar PIN** (no repite los que ya están) y **Agregar**. En la ficha también está **Historial**.
6. **Borrar** pide confirmación. Si esa persona **ya tiene asistencia**, no se borra la ficha ni se toca `kiosk_attendance`: no sabemos si la base borraría el historial en cascada, y no se cambia esa relación. Si **no** tiene asistencia, solo se quita la ficha. La bitácora, si ya existe, conserva el intento.

**Cerrar sesión** olvida el código en esa pestaña.

En la misma página, **Días que no cuentan como falta** (hace falta el SQL 10):

1. **Festivo:** fecha y nombre, por ejemplo 25/12/2026 Navidad, y **Agregar festivo**. **Editar** y **Borrar** están en la fila. Aplica a toda la empresa.
2. **Agregar descanso obligatorio de ese año** propone los de la LFT artículo 74 (Año Nuevo, Constitución, Juárez, Trabajo, Independencia, Revolución, Navidad y, cada seis años, el 1 de diciembre). No pisa los que ya están. Después se pueden cambiar el nombre o borrar. El día de la elección no viene incluido.
3. En la ficha de cada persona, la columna **Manager** elige a su jefe directo. Nadie puede ser su propio manager. Si queda en **Sin manager**, esa persona puede pedir vacaciones, pero el primer visto bueno no existe hasta que RH asigne a alguien.
4. **Cargar ya aprobadas** es la excepción: RH deja unas vacaciones aprobadas sin las dos firmas. Queda anotado como carga directa. **Aprobar** solo aparece cuando el manager ya dijo que sí. **Rechazar** puede usarse antes o después. **Cancelar** las saca del tablero.

La persona pide las suyas en `vacaciones.html` (también hay un enlace en el kiosko), con su PIN. Ve solo sus solicitudes y, si es manager, las pendientes de su equipo. No entra a la admin.

El orden es manager y después RH. Solo cuando las dos aprueban, o cuando RH cargó la excepción, el día deja de ser falta. Si cualquiera rechaza, queda rechazada. La persona puede cancelar mientras sigue pendiente.

En el tablero, esos días de lunes a viernes dejan de salir como falta. El calendario dice Festivo o Vacaciones y el CSV usa ese texto en vez de «Sin registro». Si alguien sí checó en un festivo, la checada se ve y el día igual no se cuenta como falta. Una solicitud pendiente sigue contando como falta.

## Cambiar el código de acceso

Es una protección ligera. El código viaja en la petición del navegador y, antes de correr el SQL 3, también está escrito en `checador.js`. Sirve para que altas y bajas no queden a un clic. No es una contraseña de Supabase y no alcanza para datos más sensibles.

Después de correr el paso 3, el código que vale es el de la base. Cámbialo en el SQL Editor:

```sql
update public.kiosk_settings
set value = 'tu-codigo-nuevo'
where key = 'admin_code';
```

Vuelve a correr el archivo 3 **no** regresa el código a `nfg-rh`.

`ADMIN_ACCESS_CODE_FALLBACK` en `checador.js` solo se usa si las funciones del paso 3 todavía no existen. Si quieres otro código también en ese modo previo, cambia esa constante y vuelve a publicar la página. Cuando el paso 3 ya corrió, el servidor ignora la constante: hay que escribir el valor de `kiosk_settings`.

El tablero de calendario sigue mostrando el mapa del día y el CSV con latitud, longitud, precisión y enlace. Si no hubo ubicación, esas celdas van vacías. Las fotos no van en el CSV: se revisan en la admin, porque el enlace firmado caduca.

## Cómo probar la foto

1. Corre el SQL 4 en Supabase y recarga el kiosco con HTTPS (la cámara no abre en una página suelta).
2. Escribe un PIN válido y pulsa Entrada. La primera vez tiene que salir el aviso. Cancelar no debe crear un registro.
3. Acepta, toma la foto y úsala. La pantalla dice que la entrada quedó registrada, con ubicación y con foto. Si niegas la ubicación antes, no abre la cámara y no crea un registro.
4. Niega la cámara en el navegador: el mensaje pide el permiso y en la admin no aparece una checada nueva.
5. Entra a la admin, elige a la persona y el día, y pulsa **Ver foto**. La imagen abre. Al minuto ese enlace deja de servir; el botón pide otro.

## Bitácora

Cada alta, cambio o baja de `kiosk_attendance` y de `kiosk_employees` deja una fila en `kiosk_audit_log`, aunque el cambio se haga en el SQL Editor o por la API. La fila trae el valor anterior, el nuevo, el rol (el del JWT si hay sesión, y si no el rol de la base) y la hora del servidor. Las filas se encadenan con SHA-256. La app no puede editarlas ni borrarlas.

Al correr el SQL 6, lo que ya existía queda como **registro inicial**. Lo de antes de ese momento no está en la bitácora.

Límites, dichos en corto:

- Un superusuario de Postgres puede apagar los triggers y entonces sí puede cambiar datos o reescribir la bitácora. Mientras los triggers sigan activos, ese cambio lo rechaza el trigger.
- Si alguien reescribe la bitácora y recalcula todos los hashes, la verificación de adentro vuelve a decir que está bien. Lo que lo delata es un hash guardado **fuera** de Supabase. **Verificar integridad** muestra el último hash: cópialo a un correo, a otro sistema, o a un repositorio al que no entre quien administra esta base. Si el hash de afuera no coincide, la historia se reescribió.
- Un cambio hecho con el trigger de auditoría apagado no encaja con la última entrada. La verificación lo cuenta como registro que no coincide.
- Reemplazar el archivo de la foto sin tocar el renglón no rompe la cadena. Lo nota la huella SHA-256: el botón contrasta las fotos de la lista que estás viendo.
- La bitácora no se lee con un SELECT abierto. Hace falta el código de la admin, el mismo límite ligero que el resto de esa página.

Conviene verificar seguido, guardar ese hash fuera, y no usar el usuario `postgres` para el trabajo de todos los días.

## Retención

La propuesta está en `sql/05_retencion_fotos_asistencia.sql`. No está activa. Cuando se decida borrar fotos de más de 90 días, primero se listan, después se borran por la API de Storage y al final se limpia `photo_path`. El archivo lo explica. No se programa solo.

## Riesgo de la llave anon

El código de la admin solo evita que la pantalla quede abierta de un clic. Está en `checador.js`, el repositorio es público y la llave anon del sitio puede leer y escribir `kiosk_employees` y `kiosk_attendance`, incluidos los PIN, porque el paso 3 no está aplicado. Quien tenga el enlace puede saltarse la pantalla. El bucket de fotos es privado, pero esa misma llave puede pedir una URL firmada de una foto cuya ruta ya esté en un registro. No pongas datos más sensibles detrás de esta página. El archivo `sql/02_seed_empleados.sql` también lista los PIN que ya se dieron de alta.
