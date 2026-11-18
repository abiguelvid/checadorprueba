# Checador de empleados

Tablero, kiosko y administración del registro de asistencia de Nanofactor. Los datos viven en el proyecto de Supabase `pjicnaamvuluommctphb`. **No hace falta pegar nada en otro proyecto.**

Estas páginas son HTML estático (GitHub Pages):

| Página | Archivo | Para qué |
| --- | --- | --- |
| Tablero | `external-check-in-dashboard.html` | Ver asistencia, mapa y CSV |
| Admin | `admin-empleados.html` | Registros con mapa, altas y bajas |
| Kiosko | `kiosk-check-in.html` | Entrada y salida, con foto obligatoria y ubicación si el navegador la da |

Cuando este fork publique GitHub Pages, las rutas quedan así:

- https://abiguelvid.github.io/checadorprueba/external-check-in-dashboard.html
- https://abiguelvid.github.io/checadorprueba/admin-empleados.html
- https://abiguelvid.github.io/checadorprueba/kiosk-check-in.html

Hay que fusionar el cambio a `main` antes de que Pages lo sirva. El tablero enlaza a Admin y a Kiosko.

## SQL

En el proyecto ya se corrieron `sql/01_ubicacion_kiosk_attendance.sql` y `sql/02_seed_empleados.sql`. **No hace falta volver a correrlos.**

Para la foto hay que correr, en el SQL Editor y en este orden:

1. `sql/04_foto_kiosk_attendance.sql` — columna `photo_path`, bucket privado `attendance-photos`, políticas y la función de registro con foto. **Sin este paso el kiosco nuevo no guarda la checada.** No lo corras a ciegas: léelo antes. No usa ni pide la service role.
2. `sql/05_retencion_fotos_asistencia.sql` — opcional. Solo crea funciones para listar fotos de más de 90 días y, después, limpiar la ruta. **No borra archivos y no queda programado.** El cron de ejemplo está comentado.

**No corras el paso 3** mientras el kiosko y la admin tengan que seguir con la llave anon y el esquema actual. `sql/03_seguridad_pin_y_admin.sql` queda para más adelante. Si algún día se corre, su `register_attendance` ya pide la foto del paso 4.

Nadie aplicó estos archivos desde el cambio de la foto. Quedan en el repo para que los revise quien administra Supabase.

Los PIN asignados no se republican en este documento. Están en la base y se consultan desde la admin.

## Kiosko

`kiosk-check-in.html` sigue pidiendo el PIN igual que antes. Al pulsar Entrada o Salida pide una foto y, aparte, la ubicación.

- La cámara es la frontal (`facingMode: user`). Hay vista previa, se toma la foto y se puede repetir.
- Sin foto no hay checada. Si niegan el permiso, no hay cámara o falla, sale un mensaje en español y **no se escribe el registro**.
- La foto se comprime a JPEG de máximo 640 px de ancho y se sube al bucket privado `attendance-photos`, en `empleado/fecha/archivo.jpg`. La ruta queda en `photo_path`.
- Antes de la primera foto de ese navegador aparece un aviso. El texto se edita en `AVISO_FOTO`, dentro de `checador.js`. Si lo cambias, sube `AVISO_FOTO_VERSION` para que el kiosco lo vuelva a mostrar.
- La ubicación se pide al abrir y otra vez al marcar. Si la persona acepta, el registro guarda `lat`, `lng` y `accuracy`. Si niega el permiso, tarda demasiado o el navegador falla, **la checada se guarda igual**, con esas columnas vacías, siempre que la foto sí se haya guardado.
- Un doble clic, o la misma acción repetida en menos de un minuto, no crea otro renglón. Una salida justo después de una entrada sí se guarda.
- La app de Render no está en este repo, no manda coordenadas y no manda foto. La columna acepta vacío para no romper ese otro cliente. El aparato de Nanofactor tiene que abrir esta página.
- Publica la página **después** de correr el SQL 4. Si se publica antes, el kiosco explica que falta la columna o el bucket y no registra.

## Página de admin

1. Abre `admin-empleados.html`.
2. Escribe el código de acceso (`nfg-rh` hasta que lo cambies) y pulsa **Entrar**.
3. **Registros:** elige empleado (o Todos) y una fecha en hora de Ciudad de México. Cada renglón muestra fecha y hora de CDMX, empleado, Entrada o Salida, un enlace a Google Maps y **Ver foto**. La foto se abre con una URL firmada de 60 segundos. Si no hubo coordenadas, dice `sin ubicación`. Si el registro es viejo o vino de otro cliente, dice `sin foto`.
4. Para agregar: nombre, PIN de 4 dígitos o **Generar PIN** (no repite los que ya están) y **Agregar**.
5. **Borrar** pide confirmación. Si esa persona **ya tiene asistencia**, no se borra la ficha ni se toca `kiosk_attendance`: no sabemos si la base borraría el historial en cascada, y no se puede cambiar el esquema. Si **no** tiene asistencia, solo se quita la ficha.

**Cerrar sesión** olvida el código en esa pestaña.

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
3. Acepta, toma la foto y úsala. La pantalla dice que la entrada quedó registrada, con o sin ubicación, y con foto.
4. Niega la cámara en el navegador: el mensaje pide el permiso y en la admin no aparece una checada nueva.
5. Entra a la admin, elige a la persona y el día, y pulsa **Ver foto**. La imagen abre. Al minuto ese enlace deja de servir; el botón pide otro.

## Retención

La propuesta está en `sql/05_retencion_fotos_asistencia.sql`. No está activa. Cuando se decida borrar fotos de más de 90 días, primero se listan, después se borran por la API de Storage y al final se limpia `photo_path`. El archivo lo explica. No se programa solo.

## Riesgo de la llave anon

El código de la admin solo evita que la pantalla quede abierta de un clic. Está en `checador.js`, el repositorio es público y la llave anon del sitio puede leer y escribir `kiosk_employees` y `kiosk_attendance`, incluidos los PIN, porque el paso 3 no está aplicado. Quien tenga el enlace puede saltarse la pantalla. El bucket de fotos es privado, pero esa misma llave puede pedir una URL firmada de una foto cuya ruta ya esté en un registro. No pongas datos más sensibles detrás de esta página. El archivo `sql/02_seed_empleados.sql` también lista los PIN que ya se dieron de alta.
