# Checador de empleados

Tablero, kiosko y administración del registro de asistencia de Nanofactor. Los datos viven en el proyecto de Supabase `pjicnaamvuluommctphb`. **No hace falta pegar nada en otro proyecto.**

Estas páginas son HTML estático (GitHub Pages):

| Página | Archivo | Para qué |
| --- | --- | --- |
| Tablero | `external-check-in-dashboard.html` | Ver asistencia, mapa y CSV |
| Admin | `admin-empleados.html` | Registros con mapa, altas y bajas |
| Kiosko | `kiosk-check-in.html` | Entrada y salida, con ubicación si el navegador la da |

Cuando este fork publique GitHub Pages, las rutas quedan así:

- https://abiguelvid.github.io/checadorprueba/external-check-in-dashboard.html
- https://abiguelvid.github.io/checadorprueba/admin-empleados.html
- https://abiguelvid.github.io/checadorprueba/kiosk-check-in.html

Hay que fusionar el cambio a `main` antes de que Pages lo sirva. El tablero enlaza a Admin y a Kiosko.

## SQL

En el proyecto ya se corrieron `sql/01_ubicacion_kiosk_attendance.sql` y `sql/02_seed_empleados.sql`. **No hace falta volver a correrlos, y no corras el paso 3** mientras el kiosko y la admin tengan que seguir con la llave anon y el esquema actual. El archivo `sql/03_seguridad_pin_y_admin.sql` queda en el repo para más adelante; hoy las páginas no dependen de él.

Los PIN asignados no se republican en este documento. Están en la base y se consultan desde la admin.

## Kiosko

`kiosk-check-in.html` pide la ubicación al abrir la página y otra vez al marcar.

- Si la persona acepta, el registro guarda `lat`, `lng` y `accuracy`.
- Si niega el permiso, tarda demasiado o el navegador falla, **el registro se guarda igual**, con esas columnas vacías.
- Un doble clic, o la misma acción repetida en menos de un minuto, no crea otro renglón. Una salida justo después de una entrada sí se guarda.
- La app de Render no está en este repo y no manda coordenadas. El aparato tiene que abrir esta página.

## Página de admin

1. Abre `admin-empleados.html`.
2. Escribe el código de acceso (`nfg-rh` hasta que lo cambies) y pulsa **Entrar**.
3. **Registros:** elige empleado (o Todos) y una fecha en hora de Ciudad de México. Cada renglón muestra fecha y hora de CDMX, empleado, Entrada o Salida, y un enlace a Google Maps. Si no hubo coordenadas, dice `sin ubicación`.
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

El tablero de calendario sigue mostrando el mapa del día y el CSV con latitud, longitud, precisión y enlace. Si no hubo ubicación, esas celdas van vacías.

## Riesgo de la llave anon

El código de la admin solo evita que la pantalla quede abierta de un clic. Está en `checador.js`, el repositorio es público y la llave anon del sitio puede leer y escribir `kiosk_employees` y `kiosk_attendance`, incluidos los PIN, porque el paso 3 no está aplicado. Quien tenga el enlace puede saltarse la pantalla. No pongas datos más sensibles detrás de esta página. El archivo `sql/02_seed_empleados.sql` también lista los PIN que ya se dieron de alta.
