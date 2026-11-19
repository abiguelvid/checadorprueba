-- Checador · paso 8
-- Salida a comer y regreso de comer.
--
-- NO se ejecutó contra la base. Córralo en el SQL Editor después del 04, 06 y 07.
-- Se puede correr más de una vez. No borra checadas ni fotos. No toca Storage.
--
-- La página de entrada y salida sigue funcionando si este archivo todavía no
-- se corre. Los botones de comida, en ese caso, avisan que falta este SQL y
-- no registran.
--
-- Acciones nuevas en kiosk_attendance.action:
--   lunch_out  Salida a comer. Sin foto. Solo si la persona está dentro
--              (la última checada es entrada o regreso de comer).
--   lunch_in   Regreso de comer. Sin foto. Solo si la última checada de hoy
--              (hora de Ciudad de México) es salida a comer.
-- Entrada y salida siguen pidiendo foto. La ubicación sigue siendo opcional.
-- La bitácora (sql/06) registra estos renglones igual que cualquier otro
-- insert: no hay que cambiar kiosk_audit_log.
--
-- Si la tabla ya trae un CHECK que solo permite checkin/checkout, se amplía.
-- El CHECK nuevo no revisa filas viejas (NOT VALID) para no frenar el script
-- si hubiera un valor raro.

DO $widen$
DECLARE
  r record;
  def text;
BEGIN
  FOR r IN
    SELECT c.oid, c.conname, pg_get_constraintdef(c.oid) AS def
    FROM pg_constraint c
    WHERE c.conrelid = 'public.kiosk_attendance'::regclass
      AND c.contype = 'c'
  LOOP
    def := r.def;
    IF def ILIKE '%action%'
       AND def ILIKE '%checkin%'
       AND def NOT ILIKE '%lunch_out%'
       AND r.conname <> 'kiosk_attendance_action_chk' THEN
      EXECUTE format('ALTER TABLE public.kiosk_attendance DROP CONSTRAINT %I', r.conname);
    END IF;
  END LOOP;
END
$widen$;

ALTER TABLE public.kiosk_attendance
  DROP CONSTRAINT IF EXISTS kiosk_attendance_action_chk;

ALTER TABLE public.kiosk_attendance
  ADD CONSTRAINT kiosk_attendance_action_chk
  CHECK (action IN ('checkin', 'checkout', 'lunch_out', 'lunch_in'))
  NOT VALID;

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
