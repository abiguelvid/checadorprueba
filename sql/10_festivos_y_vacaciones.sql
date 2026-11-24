-- Checador · paso 10
-- Festivos de toda la empresa y vacaciones con dos aprobaciones.
--
-- NO se ejecutó contra la base. Córralo en el SQL Editor quien administra
-- Supabase, después de leerlo. Va después de sql/09_ubicacion_obligatoria.sql
-- en la numeración; no lo modifica y no depende de él. Se puede correr más
-- de una vez.
-- No borra checadas, fotos ni empleados. No toca el kiosko ni la regla de
-- ubicación obligatoria.
--
-- Festivos:
--   public.kiosk_holidays (fecha y nombre, para toda la empresa).
--   No se precargan. La admin sugiere los de la LFT art. 74.
--
-- Manager:
--   kiosk_employees.manager_id, asignado por RH en la admin.
--   Una persona no puede ser su propio manager. Si no tiene manager, puede
--   solicitar vacaciones, pero nadie puede dar el primer visto bueno hasta
--   que RH asigne uno. RH no salta ese paso: para un caso excepcional usa
--   la carga directa, que queda aprobada y anotada como tal.
--
-- Vacaciones:
--   public.kiosk_vacation_requests. Estados:
--     pending_manager  la acaba de pedir el empleado (con su PIN)
--     pending_hr       ya la aprobó su manager; falta RH
--     approved         manager y RH aprobaron, o RH la cargó directo
--     rejected         la rechazó el manager o RH (motivo opcional)
--     cancelled        la canceló el empleado mientras estaba pendiente,
--                      o RH después
--   Solo approved cuenta en el tablero. Se empalma contra otras aprobadas
--   o pendientes de la misma persona. Rechazadas y canceladas no estorban.
--   Orden: primero el manager, después RH.
--
-- Quién ve y quién escribe:
--   La anon key no puede insertar, editar, borrar ni aprobar.
--   Solo puede leer festivos y, de las vacaciones, las fechas ya aprobadas
--   (el tablero). No ve notas, motivos ni solicitudes ajenas.
--   El empleado y el manager entran con PIN, por funciones. El PIN solo
--   devuelve lo propio o lo del equipo directo.
--   RH entra con el código de la admin.
--
-- Bitácora:
--   Cada solicitud guarda quién decidió y cuándo (manager_name,
--   manager_decided_at, hr_actor, hr_decided_at). Si ya se corrió el SQL 6,
--   el cambio también entra en kiosk_audit_log. Si el 6 se vuelve a correr
--   después, hay que volver a correr este archivo para que la bitácora
--   siga aceptando esta tabla.

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

COMMENT ON TABLE public.kiosk_holidays IS
  'Días festivos de toda la empresa. No cuentan como falta. Solo los cambia la admin.';

CREATE UNIQUE INDEX IF NOT EXISTS kiosk_holidays_date_key
  ON public.kiosk_holidays (holiday_date);

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
END $$;

ALTER TABLE public.kiosk_employees
  ADD COLUMN IF NOT EXISTS manager_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_employees_manager_not_self'
  ) THEN
    ALTER TABLE public.kiosk_employees
      ADD CONSTRAINT kiosk_employees_manager_not_self
      CHECK (manager_id IS NULL OR manager_id <> id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_employees_manager_fk'
  ) THEN
    ALTER TABLE public.kiosk_employees
      ADD CONSTRAINT kiosk_employees_manager_fk
      FOREIGN KEY (manager_id) REFERENCES public.kiosk_employees (id) ON DELETE SET NULL;
  END IF;
END $$;

COMMENT ON COLUMN public.kiosk_employees.manager_id IS
  'Manager directo. Lo asigna RH. NULL: la persona puede solicitar vacaciones, pero el primer visto bueno espera a que exista un manager.';

CREATE TABLE IF NOT EXISTS public.kiosk_vacation_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.kiosk_employees (id) ON DELETE CASCADE,
  start_date date NOT NULL,
  end_date date NOT NULL,
  note text,
  status text NOT NULL,
  source text NOT NULL DEFAULT 'solicitud',
  manager_employee_id uuid REFERENCES public.kiosk_employees (id) ON DELETE SET NULL,
  manager_name text,
  manager_decision text,
  manager_reason text,
  manager_decided_at timestamptz,
  hr_decision text,
  hr_reason text,
  hr_decided_at timestamptz,
  hr_actor text,
  cancelled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.kiosk_vacation_requests IS
  'Solicitudes de vacaciones. Solo status approved cuenta como vacaciones. La anon key solo lee fechas aprobadas.';

CREATE INDEX IF NOT EXISTS kiosk_vacation_requests_employee_idx
  ON public.kiosk_vacation_requests (employee_id, start_date);

CREATE INDEX IF NOT EXISTS kiosk_vacation_requests_status_idx
  ON public.kiosk_vacation_requests (status, employee_id);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_vacation_requests_status_chk'
  ) THEN
    ALTER TABLE public.kiosk_vacation_requests
      ADD CONSTRAINT kiosk_vacation_requests_status_chk
      CHECK (status IN ('pending_manager', 'pending_hr', 'approved', 'rejected', 'cancelled'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_vacation_requests_source_chk'
  ) THEN
    ALTER TABLE public.kiosk_vacation_requests
      ADD CONSTRAINT kiosk_vacation_requests_source_chk
      CHECK (source IN ('solicitud', 'rh_directa'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_vacation_requests_mgr_dec_chk'
  ) THEN
    ALTER TABLE public.kiosk_vacation_requests
      ADD CONSTRAINT kiosk_vacation_requests_mgr_dec_chk
      CHECK (manager_decision IS NULL OR manager_decision IN ('approved', 'rejected'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_vacation_requests_hr_dec_chk'
  ) THEN
    ALTER TABLE public.kiosk_vacation_requests
      ADD CONSTRAINT kiosk_vacation_requests_hr_dec_chk
      CHECK (hr_decision IS NULL OR hr_decision IN ('approved', 'rejected'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_vacation_requests_range'
  ) THEN
    ALTER TABLE public.kiosk_vacation_requests
      ADD CONSTRAINT kiosk_vacation_requests_range
      CHECK (
        end_date >= start_date
        AND end_date - start_date <= 365
        AND start_date BETWEEN DATE '2000-01-01' AND DATE '2100-12-31'
        AND end_date BETWEEN DATE '2000-01-01' AND DATE '2100-12-31'
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_vacation_requests_note_len'
  ) THEN
    ALTER TABLE public.kiosk_vacation_requests
      ADD CONSTRAINT kiosk_vacation_requests_note_len
      CHECK (note IS NULL OR char_length(btrim(note)) BETWEEN 1 AND 280);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.kiosk_vacation_requests_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.note := nullif(regexp_replace(btrim(coalesce(NEW.note, '')), '\s+', ' ', 'g'), '');
  NEW.manager_reason := nullif(regexp_replace(btrim(coalesce(NEW.manager_reason, '')), '\s+', ' ', 'g'), '');
  NEW.hr_reason := nullif(regexp_replace(btrim(coalesce(NEW.hr_reason, '')), '\s+', ' ', 'g'), '');
  IF NEW.note IS NOT NULL AND char_length(NEW.note) > 280 THEN
    RAISE EXCEPTION 'La nota es demasiado larga';
  END IF;
  IF NEW.manager_reason IS NOT NULL AND char_length(NEW.manager_reason) > 280 THEN
    RAISE EXCEPTION 'El motivo es demasiado largo';
  END IF;
  IF NEW.hr_reason IS NOT NULL AND char_length(NEW.hr_reason) > 280 THEN
    RAISE EXCEPTION 'El motivo es demasiado largo';
  END IF;
  IF NEW.status IN ('pending_manager', 'pending_hr', 'approved')
     AND EXISTS (
       SELECT 1
       FROM public.kiosk_vacation_requests v
       WHERE v.employee_id = NEW.employee_id
         AND v.id IS DISTINCT FROM NEW.id
         AND v.status IN ('pending_manager', 'pending_hr', 'approved')
         AND daterange(v.start_date, v.end_date, '[]')
             && daterange(NEW.start_date, NEW.end_date, '[]')
     ) THEN
    RAISE EXCEPTION 'Esas fechas se empalman con otras vacaciones aprobadas o pendientes de la misma persona';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.kiosk_vacation_requests_guard() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS kiosk_vacation_requests_guard ON public.kiosk_vacation_requests;
CREATE TRIGGER kiosk_vacation_requests_guard
  BEFORE INSERT OR UPDATE ON public.kiosk_vacation_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.kiosk_vacation_requests_guard();

ALTER TABLE public.kiosk_holidays ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kiosk_vacation_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS kiosk_holidays_select ON public.kiosk_holidays;
CREATE POLICY kiosk_holidays_select
  ON public.kiosk_holidays
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS kiosk_vacation_requests_select_approved ON public.kiosk_vacation_requests;
CREATE POLICY kiosk_vacation_requests_select_approved
  ON public.kiosk_vacation_requests
  FOR SELECT
  TO anon, authenticated
  USING (status = 'approved');

-- Sin políticas de INSERT, UPDATE ni DELETE.

REVOKE ALL ON TABLE public.kiosk_holidays FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.kiosk_vacation_requests FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'REVOKE ALL ON TABLE public.kiosk_holidays FROM service_role';
    EXECUTE 'REVOKE ALL ON TABLE public.kiosk_vacation_requests FROM service_role';
  END IF;
END $$;

GRANT SELECT (id, holiday_date, name) ON TABLE public.kiosk_holidays TO anon, authenticated;
GRANT SELECT (id, employee_id, start_date, end_date, status)
  ON TABLE public.kiosk_vacation_requests TO anon, authenticated;

CREATE OR REPLACE VIEW public.kiosk_approved_vacations
WITH (security_invoker = true) AS
SELECT id, employee_id, start_date, end_date
FROM public.kiosk_vacation_requests
WHERE status = 'approved';

COMMENT ON VIEW public.kiosk_approved_vacations IS
  'Solo vacaciones ya aprobadas, sin nota ni motivo. El tablero lee esto.';

REVOKE ALL ON TABLE public.kiosk_approved_vacations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.kiosk_approved_vacations TO anon, authenticated;

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
FROM public.kiosk_vacation_requests v
CROSS JOIN LATERAL generate_series(0, (v.end_date - v.start_date)) AS offs(n)
WHERE v.status = 'approved';

COMMENT ON VIEW public.kiosk_day_status IS
  'Días que no son falta. Las vacaciones de aquí ya están aprobadas. Sin notas.';

REVOKE ALL ON TABLE public.kiosk_day_status FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.kiosk_day_status TO anon, authenticated;

CREATE OR REPLACE FUNCTION kiosk_internal.employee_from_pin(p_pin text)
RETURNS TABLE (id uuid, name text, manager_id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_pin IS NULL OR btrim(p_pin) !~ '^[0-9]{4}$' THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT e.id, e.name, e.manager_id
  FROM public.kiosk_employees e
  WHERE lpad(btrim(e.pin::text), 4, '0') = btrim(p_pin)
  ORDER BY e.created_at NULLS LAST, e.name
  LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION kiosk_internal.employee_from_pin(text) FROM PUBLIC, anon, authenticated;

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
    RETURNING public.kiosk_holidays.id INTO v_id;
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

CREATE OR REPLACE FUNCTION public.admin_list_managers(p_code text)
RETURNS TABLE (id uuid, name text, manager_id uuid, manager_name text)
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
  SELECT e.id, e.name, e.manager_id, m.name
  FROM public.kiosk_employees e
  LEFT JOIN public.kiosk_employees m ON m.id = e.manager_id
  ORDER BY e.name;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_manager(
  p_code text,
  p_employee_id uuid,
  p_manager_id uuid
)
RETURNS TABLE (id uuid, name text, manager_id uuid, manager_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name text;
  v_manager_name text;
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;
  IF p_employee_id IS NULL THEN
    RAISE EXCEPTION 'Empleado no encontrado';
  END IF;
  IF p_manager_id IS NOT NULL AND p_manager_id = p_employee_id THEN
    RAISE EXCEPTION 'Una persona no puede ser su propio manager';
  END IF;

  SELECT e.name INTO v_name
  FROM public.kiosk_employees e
  WHERE e.id = p_employee_id;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Empleado no encontrado';
  END IF;

  IF p_manager_id IS NOT NULL THEN
    SELECT m.name INTO v_manager_name
    FROM public.kiosk_employees m
    WHERE m.id = p_manager_id;
    IF v_manager_name IS NULL THEN
      RAISE EXCEPTION 'Manager no encontrado';
    END IF;
  END IF;

  UPDATE public.kiosk_employees e
     SET manager_id = p_manager_id
   WHERE e.id = p_employee_id;

  RETURN QUERY
  SELECT p_employee_id, v_name, p_manager_id, v_manager_name;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_list_vacations(text);

CREATE OR REPLACE FUNCTION public.admin_list_vacations(p_code text)
RETURNS TABLE (
  id uuid,
  employee_id uuid,
  employee_name text,
  start_date date,
  end_date date,
  note text,
  status text,
  source text,
  manager_name text,
  manager_decision text,
  manager_reason text,
  manager_decided_at timestamptz,
  hr_decision text,
  hr_reason text,
  hr_decided_at timestamptz,
  hr_actor text
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
  SELECT
    v.id, v.employee_id, e.name, v.start_date, v.end_date, v.note,
    v.status, v.source, v.manager_name, v.manager_decision, v.manager_reason,
    v.manager_decided_at, v.hr_decision, v.hr_reason, v.hr_decided_at, v.hr_actor
  FROM public.kiosk_vacation_requests v
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
  note text,
  status text,
  source text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_note text;
  v_id uuid;
  v_name text;
  v_status text;
  v_source text;
  v_emp uuid;
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
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
    IF p_employee_id IS NULL THEN
      RAISE EXCEPTION 'Elige a la persona';
    END IF;
    SELECT e.name INTO v_name
    FROM public.kiosk_employees e
    WHERE e.id = p_employee_id;
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'Empleado no encontrado';
    END IF;

    INSERT INTO public.kiosk_vacation_requests (
      employee_id, start_date, end_date, note, status, source,
      hr_decision, hr_decided_at, hr_actor, hr_reason
    ) VALUES (
      p_employee_id, p_start, p_end, v_note, 'approved', 'rh_directa',
      'approved', now(), 'RH (carga directa)',
      'Cargada directo por RH, sin las dos aprobaciones.'
    )
    RETURNING public.kiosk_vacation_requests.id INTO v_id;
    v_status := 'approved';
    v_source := 'rh_directa';
  ELSE
    UPDATE public.kiosk_vacation_requests v
       SET start_date = p_start,
           end_date = p_end,
           note = v_note,
           employee_id = COALESCE(p_employee_id, v.employee_id)
     WHERE v.id = p_id
       AND v.status <> 'cancelled'
    RETURNING v.id, v.status, v.source, v.employee_id
      INTO v_id, v_status, v_source, v_emp;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'Esas vacaciones no se pueden editar. Si están canceladas, carga unas nuevas.';
    END IF;
    p_employee_id := v_emp;
    SELECT e.name INTO v_name
    FROM public.kiosk_employees e
    WHERE e.id = v_emp;
  END IF;

  RETURN QUERY
  SELECT v_id, p_employee_id, v_name, p_start, p_end, v_note, v_status, v_source;
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

  UPDATE public.kiosk_vacation_requests
     SET status = 'cancelled',
         cancelled_at = now(),
         hr_actor = COALESCE(hr_actor, 'RH'),
         hr_reason = COALESCE(hr_reason, 'Cancelada por RH')
   WHERE id = p_id
     AND status <> 'cancelled';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Vacaciones no encontradas o ya estaban canceladas';
  END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_decide_vacation(
  p_code text,
  p_id uuid,
  p_decision text,
  p_reason text
)
RETURNS TABLE (id uuid, status text, hr_decided_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
  v_decision text;
  v_reason text;
  v_at timestamptz;
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;

  v_decision := lower(btrim(coalesce(p_decision, '')));
  IF v_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'La decisión tiene que ser aprobar o rechazar';
  END IF;
  v_reason := nullif(regexp_replace(btrim(coalesce(p_reason, '')), '\s+', ' ', 'g'), '');

  SELECT r.status INTO v_status
  FROM public.kiosk_vacation_requests r
  WHERE r.id = p_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Solicitud no encontrada';
  END IF;

  IF v_decision = 'approved' AND v_status IS DISTINCT FROM 'pending_hr' THEN
    IF v_status = 'pending_manager' THEN
      RAISE EXCEPTION 'Primero tiene que aprobarla el manager. Si no tiene manager, asígnalo en la ficha. Para un caso excepcional usa la carga directa.';
    END IF;
    RAISE EXCEPTION 'Esta solicitud ya no está pendiente de RH';
  END IF;
  IF v_decision = 'rejected' AND v_status NOT IN ('pending_manager', 'pending_hr') THEN
    RAISE EXCEPTION 'Esta solicitud ya no se puede rechazar';
  END IF;

  v_at := now();
  UPDATE public.kiosk_vacation_requests r
     SET status = CASE WHEN v_decision = 'approved' THEN 'approved' ELSE 'rejected' END,
         hr_decision = v_decision,
         hr_reason = v_reason,
         hr_decided_at = v_at,
         hr_actor = 'RH'
   WHERE r.id = p_id;

  RETURN QUERY
  SELECT p_id, CASE WHEN v_decision = 'approved' THEN 'approved' ELSE 'rejected' END, v_at;
END;
$$;

DROP FUNCTION IF EXISTS public.vacation_portal(text);

CREATE OR REPLACE FUNCTION public.vacation_portal(p_pin text)
RETURNS TABLE (
  employee_id uuid,
  name text,
  manager_name text,
  requests jsonb,
  team jsonb,
  direct_reports integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_name text;
  v_manager uuid;
  v_manager_name text;
  v_requests jsonb;
  v_team jsonb;
  v_reports integer;
BEGIN
  SELECT p.id, p.name, p.manager_id
    INTO v_id, v_name, v_manager
  FROM kiosk_internal.employee_from_pin(p_pin) AS p;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'PIN no encontrado';
  END IF;

  SELECT m.name INTO v_manager_name
  FROM public.kiosk_employees m
  WHERE m.id = v_manager;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'start_date', r.start_date,
    'end_date', r.end_date,
    'note', r.note,
    'status', r.status,
    'source', r.source,
    'manager_name', r.manager_name,
    'manager_decision', r.manager_decision,
    'manager_reason', r.manager_reason,
    'manager_decided_at', r.manager_decided_at,
    'hr_decision', r.hr_decision,
    'hr_reason', r.hr_reason,
    'hr_decided_at', r.hr_decided_at,
    'created_at', r.created_at
  ) ORDER BY r.start_date DESC, r.created_at DESC), '[]'::jsonb)
    INTO v_requests
  FROM public.kiosk_vacation_requests r
  WHERE r.employee_id = v_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'employee_id', r.employee_id,
    'employee_name', e.name,
    'start_date', r.start_date,
    'end_date', r.end_date,
    'note', r.note,
    'status', r.status,
    'created_at', r.created_at
  ) ORDER BY r.created_at DESC), '[]'::jsonb)
    INTO v_team
  FROM public.kiosk_vacation_requests r
  JOIN public.kiosk_employees e ON e.id = r.employee_id
  WHERE e.manager_id = v_id
    AND r.status = 'pending_manager';

  SELECT count(*)::integer INTO v_reports
  FROM public.kiosk_employees e
  WHERE e.manager_id = v_id;

  RETURN QUERY
  SELECT v_id, v_name, v_manager_name, v_requests, v_team, v_reports;
END;
$$;

CREATE OR REPLACE FUNCTION public.vacation_request_create(
  p_pin text,
  p_start date,
  p_end date,
  p_note text
)
RETURNS TABLE (id uuid, status text, start_date date, end_date date, note text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_name text;
  v_note text;
  v_new uuid;
BEGIN
  SELECT p.id, p.name INTO v_id, v_name
  FROM kiosk_internal.employee_from_pin(p_pin) AS p;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'PIN no encontrado';
  END IF;

  v_note := nullif(regexp_replace(btrim(coalesce(p_note, '')), '\s+', ' ', 'g'), '');
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

  INSERT INTO public.kiosk_vacation_requests (
    employee_id, start_date, end_date, note, status, source
  ) VALUES (
    v_id, p_start, p_end, v_note, 'pending_manager', 'solicitud'
  )
  RETURNING public.kiosk_vacation_requests.id INTO v_new;

  RETURN QUERY
  SELECT v_new, 'pending_manager'::text, p_start, p_end, v_note;
END;
$$;

CREATE OR REPLACE FUNCTION public.vacation_request_cancel(p_pin text, p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_status text;
  v_n int := 0;
BEGIN
  SELECT p.id INTO v_id
  FROM kiosk_internal.employee_from_pin(p_pin) AS p;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'PIN no encontrado';
  END IF;

  SELECT r.status INTO v_status
  FROM public.kiosk_vacation_requests r
  WHERE r.id = p_id
    AND r.employee_id = v_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Solicitud no encontrada';
  END IF;
  IF v_status NOT IN ('pending_manager', 'pending_hr') THEN
    RAISE EXCEPTION 'Solo se puede cancelar mientras está pendiente del manager o de RH';
  END IF;

  UPDATE public.kiosk_vacation_requests
     SET status = 'cancelled',
         cancelled_at = now()
   WHERE id = p_id
     AND employee_id = v_id
     AND status IN ('pending_manager', 'pending_hr');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.vacation_manager_decide(
  p_pin text,
  p_id uuid,
  p_decision text,
  p_reason text
)
RETURNS TABLE (id uuid, status text, manager_decided_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_me uuid;
  v_my_name text;
  v_employee uuid;
  v_manager uuid;
  v_status text;
  v_decision text;
  v_reason text;
  v_at timestamptz;
BEGIN
  SELECT p.id, p.name INTO v_me, v_my_name
  FROM kiosk_internal.employee_from_pin(p_pin) AS p;
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'PIN no encontrado';
  END IF;

  v_decision := lower(btrim(coalesce(p_decision, '')));
  IF v_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'La decisión tiene que ser aprobar o rechazar';
  END IF;
  v_reason := nullif(regexp_replace(btrim(coalesce(p_reason, '')), '\s+', ' ', 'g'), '');

  SELECT r.employee_id, r.status, e.manager_id
    INTO v_employee, v_status, v_manager
  FROM public.kiosk_vacation_requests r
  JOIN public.kiosk_employees e ON e.id = r.employee_id
  WHERE r.id = p_id;
  IF v_employee IS NULL THEN
    RAISE EXCEPTION 'Solicitud no encontrada';
  END IF;
  IF v_manager IS NULL THEN
    RAISE EXCEPTION 'Esta persona no tiene manager asignado. RH tiene que asignarlo antes de que alguien pueda aprobar.';
  END IF;
  IF v_manager IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Esta solicitud no es de tu equipo.';
  END IF;
  IF v_status IS DISTINCT FROM 'pending_manager' THEN
    RAISE EXCEPTION 'Esta solicitud ya no está pendiente del manager';
  END IF;

  v_at := now();
  UPDATE public.kiosk_vacation_requests r
     SET status = CASE WHEN v_decision = 'approved' THEN 'pending_hr' ELSE 'rejected' END,
         manager_employee_id = v_me,
         manager_name = v_my_name,
         manager_decision = v_decision,
         manager_reason = v_reason,
         manager_decided_at = v_at
   WHERE r.id = p_id
     AND r.status = 'pending_manager';

  RETURN QUERY
  SELECT p_id,
         CASE WHEN v_decision = 'approved' THEN 'pending_hr' ELSE 'rejected' END,
         v_at;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_holidays(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_save_holiday(text, uuid, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_holiday(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_managers(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_manager(text, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_vacations(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_save_vacation(text, uuid, uuid, date, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_vacation(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_decide_vacation(text, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vacation_portal(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vacation_request_create(text, date, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vacation_request_cancel(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vacation_manager_decide(text, uuid, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_list_holidays(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_holiday(text, uuid, date, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_holiday(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_managers(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_manager(text, uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_vacations(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_vacation(text, uuid, uuid, date, date, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_vacation(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_decide_vacation(text, uuid, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vacation_portal(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vacation_request_create(text, date, date, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vacation_request_cancel(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vacation_manager_decide(text, uuid, text, text) TO anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_list_holidays(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_save_holiday(text, uuid, date, text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_delete_holiday(text, uuid) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_list_managers(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_set_manager(text, uuid, uuid) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_list_vacations(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_save_vacation(text, uuid, uuid, date, date, text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_delete_vacation(text, uuid) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_decide_vacation(text, uuid, text, text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.vacation_portal(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.vacation_request_create(text, date, date, text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.vacation_request_cancel(text, uuid) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.vacation_manager_decide(text, uuid, text, text) TO service_role';
  END IF;
END $$;

-- Engancha la bitácora solo si el SQL 6 ya creó la tabla y el trigger.
DO $audit$
BEGIN
  IF to_regclass('public.kiosk_audit_log') IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_audit_log_table_chk'
  ) THEN
    ALTER TABLE public.kiosk_audit_log DROP CONSTRAINT kiosk_audit_log_table_chk;
  END IF;

  ALTER TABLE public.kiosk_audit_log
    ADD CONSTRAINT kiosk_audit_log_table_chk
    CHECK (table_name IN ('kiosk_attendance', 'kiosk_employees', 'kiosk_vacation_requests'));

  IF to_regprocedure('kiosk_internal.audit_kiosk_change()') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS kiosk_vacation_requests_audit ON public.kiosk_vacation_requests;
    CREATE TRIGGER kiosk_vacation_requests_audit
      AFTER INSERT OR UPDATE OR DELETE ON public.kiosk_vacation_requests
      FOR EACH ROW
      EXECUTE FUNCTION kiosk_internal.audit_kiosk_change();
  END IF;
END
$audit$;

CREATE OR REPLACE FUNCTION public.admin_list_kiosk_audit(
  p_code text,
  p_table text,
  p_record_id text
)
RETURNS TABLE (
  id bigint,
  logged_at timestamptz,
  table_name text,
  record_id text,
  action text,
  old_row jsonb,
  new_row jsonb,
  actor_role text,
  actor_uid uuid,
  db_role text,
  prev_hash text,
  row_hash text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF to_regclass('public.kiosk_audit_log') IS NULL THEN
    RAISE EXCEPTION 'Falta la bitácora. Corre sql/06_bitacora_auditoria.sql en Supabase.';
  END IF;
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;
  IF p_table NOT IN ('kiosk_attendance', 'kiosk_employees', 'kiosk_vacation_requests') THEN
    RAISE EXCEPTION 'Tabla no válida';
  END IF;
  IF p_record_id IS NULL OR p_record_id !~ '^[0-9A-Za-z-]{1,80}$' THEN
    RAISE EXCEPTION 'Identificador inválido';
  END IF;

  RETURN QUERY
  SELECT
    l.id, l.logged_at, l.table_name, l.record_id, l.action,
    l.old_row, l.new_row, l.actor_role, l.actor_uid, l.db_role,
    l.prev_hash, l.row_hash
  FROM public.kiosk_audit_log AS l
  WHERE l.table_name = p_table
    AND l.record_id = p_record_id
  ORDER BY l.id DESC
  LIMIT 200;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_kiosk_audit(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_kiosk_audit(text, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
