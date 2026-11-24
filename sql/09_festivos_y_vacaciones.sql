-- Checador · paso 9
-- Festivos de toda la empresa y vacaciones por empleado.
--
-- NO se ejecutó contra la base. Córralo en el SQL Editor quien administra
-- Supabase, después de leerlo. Se puede correr más de una vez.
-- No borra checadas, fotos, empleados ni la bitácora. No toca el kiosko.
--
-- Qué deja:
--   * public.kiosk_holidays: un día y un nombre (ej. 25 dic, Navidad).
--     Aplica a toda la empresa.
--   * public.kiosk_vacations: empleado, inicio, fin y nota opcional.
--     La nota no se puede leer con la anon key.
--   * public.kiosk_day_status: días ya expandidos, para consultar después.
--     employee_id vacío = festivo de todos. Con empleado = vacaciones.
--     La etiqueta de vacaciones es solo "Vacaciones" (sin la nota).
--
-- Quién escribe:
--   La anon key y authenticated NO pueden insertar, editar ni borrar.
--   RLS está activo y no hay política de escritura. Las altas, cambios y
--   bajas pasan por admin_save_* / admin_delete_*, que piden el mismo código
--   de la admin (kiosk_settings.admin_code si ya se corrió el paso 3, y si
--   no, el de respaldo nfg-rh).
--   La anon key SÍ puede leer fechas y nombres de festivo, y las fechas de
--   vacaciones, porque el tablero las usa para no contarlas como falta.
--
-- No se precargan días. La pantalla de admin sugiere los de la LFT art. 74
-- y la responsable decide cuáles guardar. Volver a correr este archivo no
-- revive un festivo que ella haya borrado.

CREATE SCHEMA IF NOT EXISTS kiosk_internal;

CREATE OR REPLACE FUNCTION kiosk_internal.admin_code_ok(p_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF to_regprocedure('public.kiosk_admin_ok(text)') IS NOT NULL THEN
    RETURN public.kiosk_admin_ok(p_code);
  END IF;
  RETURN p_code IS NOT NULL AND p_code = 'nfg-rh';
END;
$$;

REVOKE ALL ON FUNCTION kiosk_internal.admin_code_ok(text) FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.kiosk_holidays (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  holiday_date date NOT NULL,
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.kiosk_vacations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.kiosk_employees (id) ON DELETE CASCADE,
  start_date date NOT NULL,
  end_date date NOT NULL,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.kiosk_holidays IS
  'Días festivos de toda la empresa. No cuentan como falta. Solo los cambia la admin.';
COMMENT ON TABLE public.kiosk_vacations IS
  'Vacaciones por empleado. No cuentan como falta. La nota solo sale por las funciones admin_.';
COMMENT ON COLUMN public.kiosk_vacations.note IS
  'Nota opcional de RH. No está concedida a anon ni authenticated.';

CREATE UNIQUE INDEX IF NOT EXISTS kiosk_holidays_date_key
  ON public.kiosk_holidays (holiday_date);

CREATE INDEX IF NOT EXISTS kiosk_vacations_employee_idx
  ON public.kiosk_vacations (employee_id, start_date);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_holidays_name_len'
  ) THEN
    ALTER TABLE public.kiosk_holidays
      ADD CONSTRAINT kiosk_holidays_name_len
      CHECK (char_length(btrim(name)) BETWEEN 2 AND 80);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_holidays_year_range'
  ) THEN
    ALTER TABLE public.kiosk_holidays
      ADD CONSTRAINT kiosk_holidays_year_range
      CHECK (holiday_date BETWEEN DATE '2000-01-01' AND DATE '2100-12-31');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_vacations_range'
  ) THEN
    ALTER TABLE public.kiosk_vacations
      ADD CONSTRAINT kiosk_vacations_range
      CHECK (
        end_date >= start_date
        AND end_date - start_date <= 365
        AND start_date BETWEEN DATE '2000-01-01' AND DATE '2100-12-31'
        AND end_date BETWEEN DATE '2000-01-01' AND DATE '2100-12-31'
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_vacations_note_len'
  ) THEN
    ALTER TABLE public.kiosk_vacations
      ADD CONSTRAINT kiosk_vacations_note_len
      CHECK (note IS NULL OR char_length(btrim(note)) BETWEEN 1 AND 280);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.kiosk_vacations_reject_overlap()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.note := nullif(regexp_replace(btrim(coalesce(NEW.note, '')), '\s+', ' ', 'g'), '');
  IF EXISTS (
    SELECT 1
    FROM public.kiosk_vacations v
    WHERE v.employee_id = NEW.employee_id
      AND v.id IS DISTINCT FROM NEW.id
      AND daterange(v.start_date, v.end_date, '[]')
          && daterange(NEW.start_date, NEW.end_date, '[]')
  ) THEN
    RAISE EXCEPTION 'Esas fechas se empalman con otras vacaciones de la misma persona';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.kiosk_vacations_reject_overlap() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS kiosk_vacations_overlap ON public.kiosk_vacations;
CREATE TRIGGER kiosk_vacations_overlap
  BEFORE INSERT OR UPDATE ON public.kiosk_vacations
  FOR EACH ROW
  EXECUTE FUNCTION public.kiosk_vacations_reject_overlap();

ALTER TABLE public.kiosk_holidays ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kiosk_vacations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS kiosk_holidays_select ON public.kiosk_holidays;
CREATE POLICY kiosk_holidays_select
  ON public.kiosk_holidays
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS kiosk_vacations_select ON public.kiosk_vacations;
CREATE POLICY kiosk_vacations_select
  ON public.kiosk_vacations
  FOR SELECT
  TO anon, authenticated
  USING (true);

-- Sin políticas de INSERT, UPDATE ni DELETE: con RLS activo, anon y
-- authenticated no pueden escribir. El dueño (el SQL Editor) y las
-- funciones SECURITY DEFINER de abajo sí.

REVOKE ALL ON TABLE public.kiosk_holidays FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.kiosk_vacations FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'REVOKE ALL ON TABLE public.kiosk_holidays FROM service_role';
    EXECUTE 'REVOKE ALL ON TABLE public.kiosk_vacations FROM service_role';
  END IF;
END $$;

GRANT SELECT (id, holiday_date, name) ON TABLE public.kiosk_holidays TO anon, authenticated;
GRANT SELECT (id, employee_id, start_date, end_date) ON TABLE public.kiosk_vacations TO anon, authenticated;

CREATE OR REPLACE VIEW public.kiosk_day_status
WITH (security_invoker = true) AS
SELECT
  h.holiday_date AS day,
  NULL::uuid AS employee_id,
  'festivo'::text AS kind,
  h.name AS label
FROM public.kiosk_holidays h
UNION ALL
SELECT
  (v.start_date + offs.n)::date AS day,
  v.employee_id,
  'vacaciones'::text AS kind,
  'Vacaciones'::text AS label
FROM public.kiosk_vacations v
CROSS JOIN LATERAL generate_series(0, (v.end_date - v.start_date)) AS offs(n);

COMMENT ON VIEW public.kiosk_day_status IS
  'Días que no son falta. employee_id NULL es festivo de todos. La nota de vacaciones no sale aquí.';

REVOKE ALL ON TABLE public.kiosk_day_status FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.kiosk_day_status TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_list_holidays(p_code text)
RETURNS TABLE (id uuid, holiday_date date, name text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;

  RETURN QUERY
  SELECT h.id, h.holiday_date, h.name
  FROM public.kiosk_holidays h
  ORDER BY h.holiday_date, h.name;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_save_holiday(
  p_code text,
  p_id uuid,
  p_date date,
  p_name text
)
RETURNS TABLE (id uuid, holiday_date date, name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name text;
  v_id uuid;
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;

  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  IF char_length(v_name) < 2 OR char_length(v_name) > 80 THEN
    RAISE EXCEPTION 'El nombre del festivo debe tener entre 2 y 80 caracteres';
  END IF;
  IF p_date IS NULL OR p_date < DATE '2000-01-01' OR p_date > DATE '2100-12-31' THEN
    RAISE EXCEPTION 'La fecha tiene que estar entre 2000 y 2100';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.kiosk_holidays (holiday_date, name)
    VALUES (p_date, v_name)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.kiosk_holidays h
       SET holiday_date = p_date,
           name = v_name,
           updated_at = now()
     WHERE h.id = p_id
    RETURNING h.id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'Festivo no encontrado';
    END IF;
  END IF;

  RETURN QUERY
  SELECT h.id, h.holiday_date, h.name
  FROM public.kiosk_holidays h
  WHERE h.id = v_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Esa fecha ya es festivo. Edítala si quieres cambiar el nombre.';
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_holiday(p_code text, p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n int := 0;
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Festivo no encontrado';
  END IF;

  DELETE FROM public.kiosk_holidays WHERE id = p_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Festivo no encontrado';
  END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_vacations(p_code text)
RETURNS TABLE (
  id uuid,
  employee_id uuid,
  employee_name text,
  start_date date,
  end_date date,
  note text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;

  RETURN QUERY
  SELECT v.id, v.employee_id, e.name, v.start_date, v.end_date, v.note
  FROM public.kiosk_vacations v
  JOIN public.kiosk_employees e ON e.id = v.employee_id
  ORDER BY v.start_date, e.name;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_save_vacation(
  p_code text,
  p_id uuid,
  p_employee_id uuid,
  p_start date,
  p_end date,
  p_note text
)
RETURNS TABLE (
  id uuid,
  employee_id uuid,
  employee_name text,
  start_date date,
  end_date date,
  note text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_note text;
  v_id uuid;
  v_name text;
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;
  IF p_employee_id IS NULL THEN
    RAISE EXCEPTION 'Elige a la persona';
  END IF;

  SELECT e.name INTO v_name
  FROM public.kiosk_employees e
  WHERE e.id = p_employee_id;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Empleado no encontrado';
  END IF;

  v_note := nullif(regexp_replace(btrim(coalesce(p_note, '')), '\s+', ' ', 'g'), '');
  IF v_note IS NOT NULL AND char_length(v_note) > 280 THEN
    RAISE EXCEPTION 'La nota es demasiado larga';
  END IF;
  IF p_start IS NULL OR p_end IS NULL THEN
    RAISE EXCEPTION 'Elige la fecha de inicio y la de fin';
  END IF;
  IF p_end < p_start THEN
    RAISE EXCEPTION 'La fecha de fin no puede ser anterior a la de inicio';
  END IF;
  IF p_end - p_start > 365 THEN
    RAISE EXCEPTION 'El periodo no puede pasar de un año. Divídelo si hace falta.';
  END IF;
  IF p_start < DATE '2000-01-01' OR p_end > DATE '2100-12-31' THEN
    RAISE EXCEPTION 'La fecha tiene que estar entre 2000 y 2100';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.kiosk_vacations (employee_id, start_date, end_date, note)
    VALUES (p_employee_id, p_start, p_end, v_note)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.kiosk_vacations v
       SET employee_id = p_employee_id,
           start_date = p_start,
           end_date = p_end,
           note = v_note,
           updated_at = now()
     WHERE v.id = p_id
    RETURNING v.id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'Vacaciones no encontradas';
    END IF;
  END IF;

  RETURN QUERY
  SELECT v.id, v.employee_id, v_name, v.start_date, v.end_date, v.note
  FROM public.kiosk_vacations v
  WHERE v.id = v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_vacation(p_code text, p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n int := 0;
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Vacaciones no encontradas';
  END IF;

  DELETE FROM public.kiosk_vacations WHERE id = p_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Vacaciones no encontradas';
  END IF;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_holidays(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_save_holiday(text, uuid, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_holiday(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_vacations(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_save_vacation(text, uuid, uuid, date, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_vacation(text, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_list_holidays(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_holiday(text, uuid, date, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_holiday(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_vacations(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_vacation(text, uuid, uuid, date, date, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_vacation(text, uuid) TO anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_list_holidays(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_save_holiday(text, uuid, date, text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_delete_holiday(text, uuid) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_list_vacations(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_save_vacation(text, uuid, uuid, date, date, text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_delete_vacation(text, uuid) TO service_role';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
