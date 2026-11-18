-- Checador · retención de fotos (PROPUESTA, NO ACTIVADA)
--
-- Correr este archivo NO borra fotos, NO limpia photo_path y NO crea un cron.
-- Solo deja dos funciones en el esquema kiosk_internal, que la API no publica.
-- La anon key no puede ejecutarlas.
--
-- Para qué sirven, el día que Personas lo decida (sugerencia: 90 días):
--
--   1. Ver qué fotos ya cumplieron el plazo. No borra nada:
--        select * from kiosk_internal.attendance_photos_older_than(90);
--
--   2. Borrar ESOS archivos en Storage, no con DELETE en storage.objects.
--      Borrar la fila del catálogo deja el archivo guardado y se sigue cobrando.
--      Háganlo en el Dashboard (Storage → attendance-photos) o con la API,
--      desde una máquina de confianza, con la service role que NO va en este repo:
--
--        curl -X DELETE "$SUPABASE_URL/storage/v1/object/attendance-photos" \
--          -H "apikey: $SERVICE_ROLE" \
--          -H "Authorization: Bearer $SERVICE_ROLE" \
--          -H "Content-Type: application/json" \
--          -d '{"prefixes":["uuid-empleado/2026-01-01/uuid-archivo.jpg"]}'
--
--   3. Cuando el archivo ya no exista, limpiar la ruta para que la admin
--      no ofrezca "Ver foto" de algo que ya no está:
--        select kiosk_internal.clear_old_attendance_photo_paths(90);
--
--      Si se limpia la ruta ANTES de borrar el archivo, se pierde el camino
--      y la foto queda huérfana en el bucket.
--
-- Fotos subidas cuyo registro no llegó a guardarse tampoco salen en el paso 1.
-- Esas se ven en el Dashboard del bucket y se borran a mano.
--
-- NO activar un cron hasta tener el borrado real del paso 2.
-- Ejemplo, dejado apagado a propósito (no quitar los comentarios):
--   select cron.schedule(
--     'purga-fotos-asistencia',
--     '15 8 * * *',
--     $$select kiosk_internal.attendance_photos_older_than(90)$$
--   );

CREATE SCHEMA IF NOT EXISTS kiosk_internal;

REVOKE ALL ON SCHEMA kiosk_internal FROM PUBLIC;
GRANT USAGE ON SCHEMA kiosk_internal TO postgres;

CREATE OR REPLACE FUNCTION kiosk_internal.attendance_photos_older_than(p_days integer DEFAULT 90)
RETURNS TABLE (
  photo_path text,
  marked_at timestamptz,
  employee_id uuid,
  employee_name text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF p_days IS NULL OR p_days < 1 OR p_days > 3650 THEN
    RAISE EXCEPTION 'Indica entre 1 y 3650 días';
  END IF;

  RETURN QUERY
  SELECT a.photo_path, a."timestamp", a.employee_id, a.employee_name
  FROM public.kiosk_attendance AS a
  WHERE a.photo_path IS NOT NULL
    AND a."timestamp" < now() - make_interval(days => p_days)
  ORDER BY a."timestamp";
END;
$$;

COMMENT ON FUNCTION kiosk_internal.attendance_photos_older_than(integer) IS
  'Lista fotos de asistencia más viejas que p_days. No borra archivos ni rutas.';

CREATE OR REPLACE FUNCTION kiosk_internal.clear_old_attendance_photo_paths(p_days integer DEFAULT 90)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_n integer := 0;
BEGIN
  IF p_days IS NULL OR p_days < 1 OR p_days > 3650 THEN
    RAISE EXCEPTION 'Indica entre 1 y 3650 días';
  END IF;

  UPDATE public.kiosk_attendance AS a
  SET photo_path = NULL
  WHERE a.photo_path IS NOT NULL
    AND a."timestamp" < now() - make_interval(days => p_days);

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

COMMENT ON FUNCTION kiosk_internal.clear_old_attendance_photo_paths(integer) IS
  'Pone photo_path en NULL en checadas viejas. No borra el archivo de Storage: eso va primero, por la API.';

REVOKE ALL ON FUNCTION kiosk_internal.attendance_photos_older_than(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION kiosk_internal.clear_old_attendance_photo_paths(integer) FROM PUBLIC, anon, authenticated;
