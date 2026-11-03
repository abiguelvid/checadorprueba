-- Checador · paso 3 de 3
-- La anon key deja de poder leer kiosk_employees.pin y de insertar,
-- editar o borrar empleados. El tablero sigue leyendo id y name.
-- El kiosko valida el PIN con verify_pin / register_attendance.
-- La página de admin usa las funciones admin_* con el código de acceso.
--
-- Código inicial: nfg-rh
-- Cambiarlo (no se pisa si vuelves a correr este archivo):
--   update public.kiosk_settings
--   set value = 'tu-codigo-nuevo'
--   where key = 'admin_code';
--
-- Si el kiosko de Render (external-checkin-nfg) lee el PIN con la
-- service role, sigue igual. Si lo lee con la anon key, hay que usar
-- kiosk-check-in.html de este repo o llamar a verify_pin.
-- Se puede correr más de una vez.

-- Código de admin. La anon key no puede leer esta tabla.
CREATE TABLE IF NOT EXISTS public.kiosk_settings (
  key text PRIMARY KEY,
  value text NOT NULL
);

ALTER TABLE public.kiosk_settings ENABLE ROW LEVEL SECURITY;

INSERT INTO public.kiosk_settings (key, value)
VALUES ('admin_code', 'nfg-rh')
ON CONFLICT (key) DO NOTHING;

REVOKE ALL ON TABLE public.kiosk_settings FROM PUBLIC, anon, authenticated;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'REVOKE ALL ON TABLE public.kiosk_settings FROM service_role';
  END IF;
END $$;

-- Directorio público: id, nombre y fecha. Sin PIN.
CREATE OR REPLACE VIEW public.kiosk_employees_directory
WITH (security_invoker = true) AS
SELECT id, name, created_at
FROM public.kiosk_employees;

REVOKE ALL ON TABLE public.kiosk_employees_directory FROM PUBLIC;
GRANT SELECT ON TABLE public.kiosk_employees_directory TO anon, authenticated;

-- Quitar el PIN y las escrituras directas a la anon key.
REVOKE ALL ON TABLE public.kiosk_employees FROM PUBLIC;
REVOKE ALL ON TABLE public.kiosk_employees FROM anon, authenticated;
GRANT SELECT (id, name, created_at) ON TABLE public.kiosk_employees TO anon, authenticated;

-- La asistencia no se toca: el tablero lee y el kiosko (o Render) inserta.
-- service_role conserva el acceso que ya tenía sobre kiosk_employees.

CREATE OR REPLACE FUNCTION public.kiosk_admin_ok(p_code text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_code IS NOT NULL
     AND length(btrim(p_code)) > 0
     AND EXISTS (
       SELECT 1
       FROM public.kiosk_settings s
       WHERE s.key = 'admin_code'
         AND s.value = p_code
     );
$$;

CREATE OR REPLACE FUNCTION public.verify_pin(p_pin text)
RETURNS TABLE (id uuid, name text, is_checked_in boolean)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_name text;
  v_action text;
BEGIN
  IF p_pin IS NULL OR p_pin !~ '^[0-9]{4}$' THEN
    RETURN;
  END IF;

  SELECT e.id, e.name
    INTO v_id, v_name
  FROM public.kiosk_employees e
  WHERE lpad(btrim(e.pin::text), 4, '0') = p_pin
  ORDER BY e.created_at NULLS LAST, e.name
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT a.action
    INTO v_action
  FROM public.kiosk_attendance a
  WHERE a.employee_id = v_id
  ORDER BY a."timestamp" DESC
  LIMIT 1;

  RETURN QUERY
  SELECT v_id, v_name, (v_action IS NOT DISTINCT FROM 'checkin');
END;
$$;

CREATE OR REPLACE FUNCTION public.register_attendance(
  p_pin text,
  p_action text,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_accuracy double precision DEFAULT NULL
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
  v_ts timestamptz;
  v_saved boolean := false;
BEGIN
  v_action := lower(btrim(coalesce(p_action, '')));
  IF v_action NOT IN ('checkin', 'checkout') THEN
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

  IF v_has_loc THEN
    EXECUTE $q$
      INSERT INTO public.kiosk_attendance
        (employee_id, employee_name, action, "timestamp", lat, lng, accuracy)
      VALUES ($1, $2, $3, now(), $4, $5, $6)
      RETURNING "timestamp"
    $q$
    INTO v_ts
    USING v_id, v_name, v_action, v_lat, v_lng, v_acc;
    IF v_lat IS NULL OR v_lng IS NULL THEN
      v_saved := false;
    END IF;
  ELSE
    EXECUTE $q$
      INSERT INTO public.kiosk_attendance
        (employee_id, employee_name, action, "timestamp")
      VALUES ($1, $2, $3, now())
      RETURNING "timestamp"
    $q$
    INTO v_ts
    USING v_id, v_name, v_action;
    v_saved := false;
  END IF;

  RETURN QUERY
  SELECT v_id, v_name, v_action, v_ts, v_saved;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_employees(p_code text)
RETURNS TABLE (id uuid, name text, pin text, created_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.kiosk_admin_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;

  RETURN QUERY
  SELECT e.id, e.name, lpad(btrim(e.pin::text), 4, '0'), e.created_at
  FROM public.kiosk_employees e
  ORDER BY e.name;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_add_employee(p_code text, p_name text, p_pin text)
RETURNS TABLE (id uuid, name text, pin text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name text;
  v_pin text;
  v_type text;
  v_id uuid;
  v_created timestamptz;
  v_pin_out text;
BEGIN
  IF NOT public.kiosk_admin_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;

  v_name := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_pin := trim(coalesce(p_pin, ''));

  IF char_length(v_name) < 2 THEN
    RAISE EXCEPTION 'El nombre es demasiado corto';
  END IF;
  IF v_pin !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'El PIN debe tener 4 dígitos';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.kiosk_employees e
    WHERE lower(regexp_replace(trim(e.name), '\s+', ' ', 'g')) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'Ya existe un empleado con ese nombre';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.kiosk_employees e
    WHERE lpad(btrim(e.pin::text), 4, '0') = v_pin
  ) THEN
    RAISE EXCEPTION 'Ese PIN ya está asignado';
  END IF;

  SELECT c.data_type INTO v_type
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'kiosk_employees'
    AND c.column_name = 'pin';

  IF v_type IN ('smallint', 'integer', 'bigint', 'numeric') THEN
    EXECUTE $q$
      INSERT INTO public.kiosk_employees (name, pin, created_at)
      VALUES ($1, $2::integer, now())
      RETURNING id, created_at, lpad(pin::text, 4, '0')
    $q$
    INTO v_id, v_created, v_pin_out
    USING v_name, v_pin;
  ELSE
    EXECUTE $q$
      INSERT INTO public.kiosk_employees (name, pin, created_at)
      VALUES ($1, $2, now())
      RETURNING id, created_at, pin::text
    $q$
    INTO v_id, v_created, v_pin_out
    USING v_name, v_pin;
  END IF;

  RETURN QUERY SELECT v_id, v_name, v_pin_out, v_created;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_employee(p_code text, p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n int := 0;
BEGIN
  IF NOT public.kiosk_admin_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Empleado no encontrado';
  END IF;

  BEGIN
    DELETE FROM public.kiosk_employees WHERE id = p_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
  EXCEPTION
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'No se puede borrar: este empleado tiene registros de asistencia y la base los está protegiendo. El historial se conserva.';
  END;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'Empleado no encontrado';
  END IF;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.kiosk_admin_ok(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.verify_pin(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.register_attendance(text, text, double precision, double precision, double precision) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_employees(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_add_employee(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_employee(text, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.verify_pin(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_attendance(text, text, double precision, double precision, double precision) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_employees(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_add_employee(text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_employee(text, uuid) TO anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.verify_pin(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.register_attendance(text, text, double precision, double precision, double precision) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_list_employees(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_add_employee(text, text, text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_delete_employee(text, uuid) TO service_role';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
