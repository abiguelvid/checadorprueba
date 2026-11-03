# Checador de empleados

Tablero, kiosko y administración del registro de asistencia de Nanofactor. Los datos viven en el proyecto de Supabase `pjicnaamvuluommctphb`. **No hace falta pegar nada en otro proyecto.**

Estas páginas son HTML estático (GitHub Pages):

| Página | Archivo | Para qué |
| --- | --- | --- |
| Tablero | `external-check-in-dashboard.html` | Ver asistencia, mapa y CSV |
| Admin | `admin-empleados.html` | Listar, agregar y borrar empleados |
| Kiosko | `kiosk-check-in.html` | Entrada y salida, con ubicación si el navegador la da |

Cuando este fork publique GitHub Pages, las rutas quedan así:

- https://abiguelvid.github.io/checadorprueba/external-check-in-dashboard.html
- https://abiguelvid.github.io/checadorprueba/admin-empleados.html
- https://abiguelvid.github.io/checadorprueba/kiosk-check-in.html

Hay que fusionar el cambio a `main` antes de que Pages lo sirva. El tablero enlaza a Admin y a Kiosko.

## SQL, en este orden

Ábrelo aquí: [SQL Editor del proyecto](https://supabase.com/dashboard/project/pjicnaamvuluommctphb/sql/new).

Para cada archivo: abre el archivo en el repo, copia **todo** el contenido, pégalo en una consulta nueva y pulsa **Run**. Espera a que diga Success antes del siguiente. Se pueden volver a correr: no duplican empleados y no regresan el código de admin si ya lo cambiaste.

1. `sql/01_ubicacion_kiosk_attendance.sql`  
   Agrega `lat`, `lng` y `accuracy` a `kiosk_attendance`. Las tres aceptan vacío.

2. `sql/02_seed_empleados.sql`  
   Da de alta a las 19 personas de la tabla de abajo, con su PIN. Si el nombre ya existe (aunque tenga espacios dobles), no lo duplica y no le cambia el PIN. En **Messages** verás `Alta: …` o `Sin cambios, ya existe: …`.  
   Erick Torres no entra en esta lista: se queda con el PIN **5293**.

3. `sql/03_seguridad_pin_y_admin.sql`  
   Quita el PIN de lo que puede leer la llave pública del sitio, y crea las funciones del kiosko y de la admin. El código de acceso inicial es `nfg-rh`.

Si el kiosko dice que no puede validar el PIN justo después del paso 3, espera un minuto y recarga. El aviso del final del archivo le pide a Supabase que recargue el esquema. Si sigue igual, corre solo esta línea:

```sql
notify pgrst, 'reload schema';
```

## Página de admin

1. Abre `admin-empleados.html`.
2. Escribe el código de acceso (`nfg-rh` hasta que lo cambies) y pulsa **Entrar**.
3. La tabla muestra nombre, PIN y fecha de alta.
4. Para agregar: escribe el nombre, escribe un PIN de 4 dígitos o pulsa **Generar PIN** (no repite los de la lista) y pulsa **Agregar**.
5. Para borrar: **Borrar** y confirma. La persona ya no puede checar. Sus registros de asistencia se quedan. Si la base no deja borrarla porque esos registros están ligados, el mensaje lo dice y no se borra nada.

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

## Ubicación en entrada y salida

`kiosk-check-in.html` pide la ubicación del navegador en cada entrada y en cada salida.

- Si la persona acepta, se guardan latitud, longitud y precisión.
- Si niega el permiso, tarda demasiado o el navegador falla, **el registro se guarda igual**, sin ubicación.
- En el tablero, el día muestra **mapa** y, al pasar el cursor o tocar el día, un enlace a Google Maps por entrada y por salida.
- El CSV del periodo incluye latitud, longitud, precisión y el enlace. Si ese registro no tiene ubicación, esas celdas van vacías.

La app que hoy está en Render (`https://external-checkin-nfg.onrender.com/`) **no está en este repo** y no manda coordenadas. Para guardar ubicación, el aparato del kiosko tiene que abrir `kiosk-check-in.html`.

Esa app de Render sigue pudiendo leer empleados si usa la llave `service_role`. Si en cambio lee la columna `pin` con la llave anon, dejará de funcionar después del paso 3: hay que pasar el aparato a `kiosk-check-in.html`.

## Si el SQL todavía no se ha corrido

Las páginas no se rompen:

- Sin las columnas de ubicación, el registro y el tablero siguen como antes (sin mapa).
- Sin las funciones nuevas, el kiosko busca el PIN directo en la tabla y la admin usa el código `nfg-rh` de `checador.js`.
- Cuando el paso 3 ya corrió, la llave pública ya no puede leer `pin` ni dar de alta o de baja directo. Eso pasa por `verify_pin`, `register_attendance` y las funciones `admin_*`, que sí revisan el código.

## PIN de las 19 personas

PIN de 4 dígitos, todos distintos, ninguno es 5293.

| Nombre | PIN |
| --- | --- |
| LEON ALBARRAN MENA | 2465 |
| MONICA RABASA | 3352 |
| PAULINA CÓRDOVA WALTERSPIEL | 3656 |
| VIVIANA ABIGUEL VIDAL HERRERA | 3671 |
| DIEGO ANTONIO PONCE ELIZALDE | 4181 |
| ABRAHAM DEL RÍO MONTERROSO | 3188 |
| RODRIGO LEO SAINT ANDRE | 1895 |
| GWYNETH VALERIA MORALES CASTRO | 9663 |
| ENRIQUE RODRIGUEZ JIMENEZ | 5160 |
| JORGE URIEL MENDOZA BOBADILLA | 9678 |
| RICARDO ARTEMIO GARCÍA GARCÍA | 9328 |
| ROBERTO GONZALEZ FUENTES | 2874 |
| CARLOS EDUARDO PEREZ JASSO | 3921 |
| ANA KAREN ANDRADE VELEZ | 8418 |
| ANGEL SANCHEZ JIMENEZ | 4101 |
| MANUEL ABRAHAM PINKUS RODRÍGUEZ | 6324 |
| NIVARDO ADRIÁN ZACATECO PRAXEDIZ | 9209 |
| FRANCISCO IVÁN GONZÁLEZ MARTÍNEZ | 3935 |
| JESÚS RODRIGO LÓPEZ ORDAZ | 6120 |

Los espacios dobles del listado original se unieron. Acentos y mayúsculas se dejaron como venían.
