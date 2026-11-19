-- Checador · paso 4
-- Foto de la checada, sin reconocimiento facial.
--
-- NO se ejecutó contra la base. Lo corre a mano quien administra Supabase,
-- en el SQL Editor del proyecto pjicnaamvuluommctphb, después de leerlo.
-- Se puede correr más de una vez. No borra filas ni fotos.
--
-- Orden:
--   1. sql/01 y sql/02 ya están aplicados. No los vuelvas a correr.
--   2. Corre ESTE archivo y después sql/06_bitacora_auditoria.sql
--      antes de publicar el kiosco nuevo. El 04 crea la foto; el 06
--      crea la huella y la bitácora. Sin photo_sha256 el registro no se guarda.
--   3. sql/05_retencion_fotos_asistencia.sql es opcional: solo crea
--      funciones y no borra nada. No lo programes con cron.
--   4. sql/03 sigue siendo el cierre de PIN, para más adelante.
--      Este archivo no quita el acceso anon al PIN.
--
-- Qué hace:
--   * Columna public.kiosk_attendance.photo_path (NULL en registros viejos).
--   * Bucket PRIVADO attendance-photos, JPEG, tope 500 KB.
--   * La anon key puede SUBIR una ruta uuid/fecha/uuid.jpg de un empleado
--     que ya existe. No puede listar el bucket ni reemplazar archivos.
--   * Puede pedir una URL firmada solo de una foto ya ligada a una checada,
--     y solo para la operación de firma, si esta versión de Storage
--     tiene storage.allow_any_operation. Si no la tiene, la política de
--     respaldo deja leer esas rutas con la anon key (el bucket sigue privado).
--   * Si register_attendance ya existe (paso 3), la reemplaza para exigir foto.
--     Si no existe, la crea: el kiosco la usa en cuanto este archivo corre.
--     No inserta sin photo_path. Otro cliente que inserte directo en la tabla
--     (por ejemplo el kiosco de Render) puede seguir sin foto: la columna
--     acepta NULL a propósito.
--
-- La anon key ya está en la página pública y hoy puede leer la asistencia.
-- El bucket no es público: un enlace sin firma no abre la foto. Quien tenga
-- la anon key puede pedir una firma de una ruta que ya esté en photo_path,
-- igual que hoy puede leer el renglón. La firma dura 60 segundos (la pide
-- la admin al pulsar "Ver foto"). No pegues la service role en ningún archivo.

ALTER TABLE public.kiosk_attendance
  ADD COLUMN IF NOT EXISTS photo_path text;

COMMENT ON COLUMN public.kiosk_attendance.photo_path IS
  'Ruta dentro del bucket privado attendance-photos (empleado/fecha/archivo.jpg). NULL en registros anteriores o en clientes que no mandan foto. El kiosco de este repo no registra sin foto.';

ALTER TABLE public.kiosk_attendance
  DROP CONSTRAINT IF EXISTS kiosk_attendance_photo_path_format;

ALTER TABLE public.kiosk_attendance
  ADD CONSTRAINT kiosk_attendance_photo_path_format
  CHECK (
    photo_path IS NULL
    OR photo_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
  );

CREATE INDEX IF NOT EXISTS kiosk_attendance_photo_path_idx
  ON public.kiosk_attendance (photo_path)
  WHERE photo_path IS NOT NULL;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'attendance-photos',
  'attendance-photos',
  false,
  512000,
  ARRAY['image/jpeg']::text[]
)
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- storage.objects ya tiene RLS activo y la tabla es de supabase_storage_admin.
-- El rol postgres del SQL Editor no puede hacer ALTER, COMMENT ni OWNER sobre
-- storage.objects ni storage.buckets (ERROR 42501). Las políticas de abajo sí
-- se pueden crear desde el editor.

CREATE SCHEMA IF NOT EXISTS kiosk_internal;

REVOKE ALL ON SCHEMA kiosk_internal FROM PUBLIC;
GRANT USAGE ON SCHEMA kiosk_internal TO anon, authenticated;

-- Solo dice si esa ruta ya está en una checada. No devuelve la foto.
-- Vive fuera de public para que PostgREST no la publique.
CREATE OR REPLACE FUNCTION kiosk_internal.attendance_photo_registered(p_path text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.kiosk_attendance AS a
    WHERE a.photo_path = p_path
  );
$$;

REVOKE ALL ON FUNCTION kiosk_internal.attendance_photo_registered(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION kiosk_internal.attendance_photo_registered(text) TO anon, authenticated;

DROP POLICY IF EXISTS attendance_photos_insert ON storage.objects;
-- Dentro del EXISTS, "name" a secas es kiosk_employees.name (el nombre de la
-- persona), no la ruta del archivo. Hay que escribir storage.objects.name.
CREATE POLICY attendance_photos_insert
ON storage.objects
FOR INSERT
TO anon, authenticated
WITH CHECK (
  bucket_id = 'attendance-photos'
  AND storage.extension(name) = 'jpg'
  AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
  AND EXISTS (
    SELECT 1
    FROM public.kiosk_employees AS e
    WHERE e.id::text = (storage.foldername(storage.objects.name))[1]
  )
);

DROP POLICY IF EXISTS attendance_photos_sign ON storage.objects;

DO $policy$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'storage'
      AND p.proname = 'allow_any_operation'
  ) THEN
    EXECUTE $sql$
      CREATE POLICY attendance_photos_sign
      ON storage.objects
      FOR SELECT
      TO anon, authenticated
      USING (
        bucket_id = 'attendance-photos'
        AND storage.allow_any_operation(ARRAY['storage.object.sign', 'storage.object.sign_many'])
        AND kiosk_internal.attendance_photo_registered(name)
      )
    $sql$;
  ELSE
    EXECUTE $sql$
      CREATE POLICY attendance_photos_sign
      ON storage.objects
      FOR SELECT
      TO anon, authenticated
      USING (
        bucket_id = 'attendance-photos'
        AND kiosk_internal.attendance_photo_registered(name)
      )
    $sql$;
    RAISE NOTICE 'Esta versión de Storage no tiene allow_any_operation. La anon key puede leer las fotos ya ligadas a una checada. El bucket sigue siendo privado.';
  END IF;
END
$policy$;

-- No hay política de UPDATE ni DELETE para anon: cada foto lleva un nombre nuevo.
-- No borres filas de storage.objects a mano: eso quita el registro y el archivo
-- puede seguir ocupando espacio. El borrado va por la API de Storage (ver sql/05).

-- Misma función que sql/03. Así el 04 sirve aunque el paso 3 no se haya corrido.
DROP FUNCTION IF EXISTS public.register_attendance(text, text, double precision, double precision, double precision);
DROP FUNCTION IF EXISTS public.register_attendance(text, text, double precision, double precision, double precision, text);
DROP FUNCTION IF EXISTS public.register_attendance(text, text, double precision, double precision, double precision, text, text);

CREATE OR REPLACE FUNCTION public.register_attendance(
  p_pin text,
  p_action text,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_accuracy double precision DEFAULT NULL,
  p_photo_path text DEFAULT NULL,
  p_photo_sha256 text DEFAULT NULL
)
RETURNS TABLE (
  employee_id uuid,
  employee_name text,
  action text,
  marked_at timestamptz,
  saved_location boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_name text;
  v_action text;
  v_lat double precision;
  v_lng double precision;
  v_acc double precision;
  v_has_loc boolean;
  v_has_photo boolean;
  v_has_sha boolean;
  v_photo text;
  v_sha text;
  v_ts timestamptz;
  v_saved boolean := false;
  v_last_action text;
  v_last_ts timestamptz;
  v_day_start timestamptz;
BEGIN
  v_action := lower(btrim(coalesce(p_action, '')));
  IF v_action NOT IN ('checkin', 'checkout', 'lunch_out', 'lunch_in') THEN
    RAISE EXCEPTION 'Acción no válida';
  END IF;
  IF p_pin IS NULL OR p_pin !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'PIN no encontrado';
  END IF;

  SELECT e.id, e.name
    INTO v_id, v_name
  FROM public.kiosk_employees e
  WHERE lpad(btrim(e.pin::text), 4, '0') = p_pin
  ORDER BY e.created_at NULLS LAST, e.name
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PIN no encontrado';
  END IF;

  IF v_action IN ('checkin', 'checkout') THEN
    v_photo := btrim(coalesce(p_photo_path, ''));
    IF v_photo !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$' THEN
      RAISE EXCEPTION 'Falta la foto. No se registró la asistencia.';
    END IF;
    IF split_part(v_photo, '/', 1) IS DISTINCT FROM v_id::text THEN
      RAISE EXCEPTION 'La foto no corresponde al empleado. No se registró la asistencia.';
    END IF;
    v_sha := lower(btrim(coalesce(p_photo_sha256, '')));
    IF v_sha !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'Falta la huella de la foto. No se registró la asistencia.';
    END IF;
  ELSE
    v_photo := NULL;
    v_sha := NULL;
  END IF;

  SELECT a.action, a."timestamp"
    INTO v_last_action, v_last_ts
  FROM public.kiosk_attendance a
  WHERE a.employee_id = v_id
  ORDER BY a."timestamp" DESC
  LIMIT 1;

  v_day_start := date_trunc('day', now() AT TIME ZONE 'America/Mexico_City') AT TIME ZONE 'America/Mexico_City';

  IF v_action = 'lunch_out' THEN
    IF v_last_action IS NULL OR v_last_action NOT IN ('checkin', 'lunch_in') THEN
      RAISE EXCEPTION 'No hay una entrada abierta. Marca Entrada antes de salir a comer.';
    END IF;
  ELSIF v_action = 'lunch_in' THEN
    IF v_last_action IS DISTINCT FROM 'lunch_out'
       OR v_last_ts IS NULL
       OR v_last_ts < v_day_start
       OR v_last_ts >= v_day_start + interval '1 day' THEN
      RAISE EXCEPTION 'No hay una salida a comer de hoy. Marca Salida a comer antes del regreso.';
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.kiosk_attendance a
    WHERE a.employee_id = v_id
      AND a.action = v_action
      AND a."timestamp" > now() - interval '60 seconds'
  ) THEN
    RAISE EXCEPTION 'Esta acción ya se registró hace un momento. Espera un minuto para no duplicarla.';
  END IF;

  v_lat := NULL;
  v_lng := NULL;
  v_acc := NULL;
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL
     AND p_lat BETWEEN -90 AND 90
     AND p_lng BETWEEN -180 AND 180 THEN
    v_lat := p_lat;
    v_lng := p_lng;
    v_saved := true;
    IF p_accuracy IS NOT NULL AND p_accuracy >= 0 AND p_accuracy < 1000000 THEN
      v_acc := p_accuracy;
    END IF;
  END IF;

  SELECT
    EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'kiosk_attendance' AND column_name = 'lat'
    )
    AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'kiosk_attendance' AND column_name = 'lng'
    )
    AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'kiosk_attendance' AND column_name = 'accuracy'
    )
  INTO v_has_loc;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'kiosk_attendance' AND column_name = 'photo_path'
  ) INTO v_has_photo;

  IF NOT v_has_photo THEN
    RAISE EXCEPTION 'Falta la columna photo_path. Corre sql/04_foto_kiosk_attendance.sql. No se registró la asistencia.';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'kiosk_attendance' AND column_name = 'photo_sha256'
  ) INTO v_has_sha;

  IF NOT v_has_sha THEN
    RAISE EXCEPTION 'Falta la columna photo_sha256. Corre sql/06_bitacora_auditoria.sql. No se registró la asistencia.';
  END IF;

  IF v_has_loc THEN
    EXECUTE $q$
      INSERT INTO public.kiosk_attendance
        (employee_id, employee_name, action, "timestamp", lat, lng, accuracy, photo_path, photo_sha256)
      VALUES ($1, $2, $3, now(), $4, $5, $6, $7, $8)
      RETURNING "timestamp"
    $q$
    INTO v_ts
    USING v_id, v_name, v_action, v_lat, v_lng, v_acc, v_photo, v_sha;
    IF v_lat IS NULL OR v_lng IS NULL THEN
      v_saved := false;
    END IF;
  ELSE
    EXECUTE $q$
      INSERT INTO public.kiosk_attendance
        (employee_id, employee_name, action, "timestamp", photo_path, photo_sha256)
      VALUES ($1, $2, $3, now(), $4, $5)
      RETURNING "timestamp"
    $q$
    INTO v_ts
    USING v_id, v_name, v_action, v_photo, v_sha;
    v_saved := false;
  END IF;

  RETURN QUERY
  SELECT v_id, v_name, v_action, v_ts, v_saved;
END;
$$;

REVOKE ALL ON FUNCTION public.register_attendance(text, text, double precision, double precision, double precision, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_attendance(text, text, double precision, double precision, double precision, text, text) TO anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.register_attendance(text, text, double precision, double precision, double precision, text, text) TO service_role';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
