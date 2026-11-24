-- Checador · paso 14
-- Saldo de vacaciones por antigüedad (LFT art. 76, reforma 2023)
-- y días personales.
--
-- NO se ejecutó contra la base de producción. Córralo en el SQL Editor
-- después del 13. Se puede correr más de una vez.
-- No borra solicitudes, festivos, empleados ni checadas. No toca la ubicación.
-- No crea una tabla nueva: fecha_ingreso va en kiosk_employees (ya auditada)
-- y el tipo va en kiosk_vacation_requests (ya admitida por el SQL 13).
--
-- Supuestos:
--   * created_at del checador no es la fecha de ingreso. Si fecha_ingreso
--     está vacía, no se pueden pedir vacaciones. RH la captura en la admin.
--   * El derecho se gana al cumplir cada año: año 1 = 12, 2 = 14, 3 = 16,
--     4 = 18, 5 = 20, años 6 a 10 = 22 y de ahí +2 cada 5 años.
--   * Antes del primer aniversario el saldo es 0.
--   * El periodo vigente va del último aniversario al día anterior del
--     siguiente. No hay arrastre del periodo anterior.
--   * Una solicitud de vacaciones tiene que caer entera en ese periodo.
--   * Un día cuenta si es lunes a viernes y no es festivo de la empresa.
--   * Disponible = derecho − aprobados − pendientes de ese periodo.
--   * RH puede forzar la carga directa de vacaciones (forzar_saldo) cuando
--     el número de días pasa el saldo. Sigue exigiendo fecha de ingreso,
--     el periodo vigente y las reglas de días personales y empalmes.
--   * Días personales: 5 por año calendario, máximo 2 en el mismo mes.
--     No se empalman con nada y no pueden caer en el día hábil inmediato
--     anterior o posterior a vacaciones pendientes o aprobadas.
--
-- Al final hay una consulta. anio_1 tiene que ser 12 y anio_31 tiene que ser 32.

ALTER TABLE public.kiosk_employees
  ADD COLUMN IF NOT EXISTS fecha_ingreso date;

COMMENT ON COLUMN public.kiosk_employees.fecha_ingreso IS
  'Fecha real de ingreso. La captura RH. No es created_at del checador. Sin ella no hay saldo de vacaciones.';

ALTER TABLE public.kiosk_vacation_requests
  ADD COLUMN IF NOT EXISTS request_type text;

ALTER TABLE public.kiosk_vacation_requests
  ADD COLUMN IF NOT EXISTS forzar_saldo boolean;

UPDATE public.kiosk_vacation_requests
   SET request_type = 'vacaciones'
 WHERE request_type IS NULL;

UPDATE public.kiosk_vacation_requests
   SET forzar_saldo = false
 WHERE forzar_saldo IS NULL;

ALTER TABLE public.kiosk_vacation_requests
  ALTER COLUMN request_type SET DEFAULT 'vacaciones';

ALTER TABLE public.kiosk_vacation_requests
  ALTER COLUMN forzar_saldo SET DEFAULT false;

DO $$
BEGIN
  UPDATE public.kiosk_vacation_requests
     SET request_type = 'vacaciones'
   WHERE request_type IS NULL;
  UPDATE public.kiosk_vacation_requests
     SET forzar_saldo = false
   WHERE forzar_saldo IS NULL;
  ALTER TABLE public.kiosk_vacation_requests
    ALTER COLUMN request_type SET NOT NULL;
  ALTER TABLE public.kiosk_vacation_requests
    ALTER COLUMN forzar_saldo SET NOT NULL;
EXCEPTION
  WHEN others THEN
    NULL;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_vacation_requests_type_chk'
  ) THEN
    ALTER TABLE public.kiosk_vacation_requests
      ADD CONSTRAINT kiosk_vacation_requests_type_chk
      CHECK (request_type IN ('vacaciones', 'personal'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION kiosk_internal.lft_vacation_days(p_year integer)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
#variable_conflict use_column
BEGIN
  IF p_year IS NULL OR p_year < 1 THEN
    RETURN 0;
  END IF;
  IF p_year = 1 THEN RETURN 12; END IF;
  IF p_year = 2 THEN RETURN 14; END IF;
  IF p_year = 3 THEN RETURN 16; END IF;
  IF p_year = 4 THEN RETURN 18; END IF;
  IF p_year = 5 THEN RETURN 20; END IF;
  RETURN 22 + 2 * ((p_year - 6) / 5);
END;
$$;

REVOKE ALL ON FUNCTION kiosk_internal.lft_vacation_days(integer) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION kiosk_internal.is_working_day(p_day date)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT p_day IS NOT NULL
     AND EXTRACT(DOW FROM p_day) NOT IN (0, 6)
     AND NOT EXISTS (
       SELECT 1
       FROM public.kiosk_holidays h
       WHERE h.holiday_date = p_day
     );
$$;

REVOKE ALL ON FUNCTION kiosk_internal.is_working_day(date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION kiosk_internal.shift_working_day(p_day date, p_step integer)
RETURNS date
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_day date := p_day;
  v_guard integer := 0;
BEGIN
  IF p_day IS NULL OR p_step = 0 THEN
    RETURN p_day;
  END IF;
  LOOP
    v_day := v_day + p_step;
    v_guard := v_guard + 1;
    EXIT WHEN kiosk_internal.is_working_day(v_day) OR v_guard > 21;
  END LOOP;
  RETURN v_day;
END;
$$;

REVOKE ALL ON FUNCTION kiosk_internal.shift_working_day(date, integer) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION kiosk_internal.span_working_days(
  p_start date,
  p_end date,
  p_from date,
  p_to date
)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(count(*)::integer, 0)
  FROM generate_series(
    GREATEST(p_start, p_from),
    LEAST(p_end, p_to),
    interval '1 day'
  ) AS g(day)
  WHERE GREATEST(p_start, p_from) <= LEAST(p_end, p_to)
    AND g.day::date BETWEEN p_from AND p_to
    AND kiosk_internal.is_working_day(g.day::date);
$$;

REVOKE ALL ON FUNCTION kiosk_internal.span_working_days(date, date, date, date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION kiosk_internal.vacation_period(p_hire date, p_on date)
RETURNS TABLE (
  completed_years integer,
  period_start date,
  period_end date,
  entitled integer,
  next_anniversary date
)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_years integer;
  v_start date;
BEGIN
  IF p_hire IS NULL OR p_on IS NULL OR p_on < p_hire THEN
    completed_years := 0;
    period_start := NULL;
    period_end := NULL;
    entitled := 0;
    next_anniversary := CASE WHEN p_hire IS NULL THEN NULL ELSE (p_hire + interval '1 year')::date END;
    RETURN NEXT;
    RETURN;
  END IF;

  v_years := date_part('year', age(p_on::timestamp, p_hire::timestamp))::integer;
  IF v_years < 1 THEN
    completed_years := 0;
    period_start := p_hire;
    period_end := (p_hire + interval '1 year' - interval '1 day')::date;
    entitled := 0;
    next_anniversary := (p_hire + interval '1 year')::date;
  ELSE
    v_start := (p_hire + make_interval(years => v_years))::date;
    completed_years := v_years;
    period_start := v_start;
    period_end := (v_start + interval '1 year' - interval '1 day')::date;
    entitled := kiosk_internal.lft_vacation_days(v_years);
    next_anniversary := (v_start + interval '1 year')::date;
  END IF;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION kiosk_internal.vacation_period(date, date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION kiosk_internal.booked_working_days(
  p_employee uuid,
  p_type text,
  p_statuses text[],
  p_from date,
  p_to date,
  p_exclude uuid
)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(sum(kiosk_internal.span_working_days(r.start_date, r.end_date, p_from, p_to)), 0)::integer
  FROM public.kiosk_vacation_requests r
  WHERE r.employee_id = p_employee
    AND coalesce(r.request_type, 'vacaciones') = p_type
    AND r.status = ANY (p_statuses)
    AND (p_exclude IS NULL OR r.id IS DISTINCT FROM p_exclude)
    AND r.end_date >= p_from
    AND r.start_date <= p_to;
$$;

REVOKE ALL ON FUNCTION kiosk_internal.booked_working_days(uuid, text, text[], date, date, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION kiosk_internal.balance_json(p_employee uuid, p_on date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_hire date;
  v_on date;
  v_period record;
  v_used integer;
  v_pending integer;
  v_year_start date;
  v_year_end date;
  v_month_start date;
  v_month_end date;
  v_personal_used_year integer;
  v_personal_pending_year integer;
  v_personal_used_month integer;
  v_personal_pending_month integer;
BEGIN
  v_on := coalesce(p_on, (now() AT TIME ZONE 'America/Mexico_City')::date);
  SELECT e.fecha_ingreso INTO v_hire
  FROM public.kiosk_employees e
  WHERE e.id = p_employee;

  SELECT * INTO v_period
  FROM kiosk_internal.vacation_period(v_hire, v_on);

  IF v_period.period_start IS NULL THEN
    v_used := 0;
    v_pending := 0;
  ELSE
    v_used := kiosk_internal.booked_working_days(
      p_employee, 'vacaciones', ARRAY['approved'], v_period.period_start, v_period.period_end, NULL
    );
    v_pending := kiosk_internal.booked_working_days(
      p_employee, 'vacaciones', ARRAY['pending_manager', 'pending_hr'], v_period.period_start, v_period.period_end, NULL
    );
  END IF;

  v_year_start := date_trunc('year', v_on::timestamp)::date;
  v_year_end := (v_year_start + interval '1 year' - interval '1 day')::date;
  v_month_start := date_trunc('month', v_on::timestamp)::date;
  v_month_end := (v_month_start + interval '1 month' - interval '1 day')::date;

  v_personal_used_year := kiosk_internal.booked_working_days(
    p_employee, 'personal', ARRAY['approved'], v_year_start, v_year_end, NULL
  );
  v_personal_pending_year := kiosk_internal.booked_working_days(
    p_employee, 'personal', ARRAY['pending_manager', 'pending_hr'], v_year_start, v_year_end, NULL
  );
  v_personal_used_month := kiosk_internal.booked_working_days(
    p_employee, 'personal', ARRAY['approved'], v_month_start, v_month_end, NULL
  );
  v_personal_pending_month := kiosk_internal.booked_working_days(
    p_employee, 'personal', ARRAY['pending_manager', 'pending_hr'], v_month_start, v_month_end, NULL
  );

  RETURN jsonb_build_object(
    'fecha_ingreso', v_hire,
    'aviso', CASE
      WHEN v_hire IS NULL THEN 'Falta la fecha de ingreso. RH tiene que capturarla para poder pedir vacaciones.'
      WHEN v_period.completed_years < 1 THEN 'Aún no cumples un año. El derecho de vacaciones empieza el ' || to_char(v_period.next_anniversary, 'DD/MM/YYYY') || '.'
      ELSE NULL
    END,
    'aniversario', v_period.completed_years,
    'periodo_inicio', v_period.period_start,
    'periodo_fin', v_period.period_end,
    'dias_derecho', v_period.entitled,
    'dias_usados', v_used,
    'dias_pendientes', v_pending,
    'dias_disponibles', GREATEST(v_period.entitled - v_used - v_pending, 0),
    'personales_usados_anio', v_personal_used_year + v_personal_pending_year,
    'personales_disponibles_anio', GREATEST(5 - v_personal_used_year - v_personal_pending_year, 0),
    'personales_usados_mes', v_personal_used_month + v_personal_pending_month,
    'personales_disponibles_mes', GREATEST(2 - v_personal_used_month - v_personal_pending_month, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION kiosk_internal.balance_json(uuid, date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION kiosk_internal.assert_time_off(p_row public.kiosk_vacation_requests)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_type text;
  v_hire date;
  v_period record;
  v_days integer;
  v_outside integer;
  v_used integer;
  v_pending integer;
  v_available integer;
  v_day date;
  v_neighbor date;
  v_year integer;
  v_month integer;
  v_chunk integer;
  v_already integer;
  v_guard integer;
BEGIN
  IF p_row.status IS NULL OR p_row.status NOT IN ('pending_manager', 'pending_hr', 'approved') THEN
    RETURN;
  END IF;

  v_type := coalesce(p_row.request_type, 'vacaciones');
  IF v_type NOT IN ('vacaciones', 'personal') THEN
    RAISE EXCEPTION 'El tipo tiene que ser vacaciones o día personal';
  END IF;

  v_days := kiosk_internal.span_working_days(p_row.start_date, p_row.end_date, p_row.start_date, p_row.end_date);
  IF v_days < 1 THEN
    RAISE EXCEPTION 'Elige al menos un día hábil. Fines de semana y festivos no cuentan.';
  END IF;

  IF v_type = 'vacaciones' THEN
    SELECT e.fecha_ingreso INTO v_hire
    FROM public.kiosk_employees e
    WHERE e.id = p_row.employee_id;
    IF v_hire IS NULL THEN
      RAISE EXCEPTION 'Falta la fecha de ingreso. RH tiene que capturarla antes de pedir vacaciones.';
    END IF;

    SELECT * INTO v_period
    FROM kiosk_internal.vacation_period(v_hire, (now() AT TIME ZONE 'America/Mexico_City')::date);
    IF v_period.completed_years < 1 THEN
      RAISE EXCEPTION 'Aún no cumples un año. El derecho de vacaciones empieza el %.',
        to_char(v_period.next_anniversary, 'DD/MM/YYYY');
    END IF;

    v_outside := v_days - kiosk_internal.span_working_days(
      p_row.start_date, p_row.end_date, v_period.period_start, v_period.period_end
    );
    IF v_outside > 0 THEN
      RAISE EXCEPTION 'Esas fechas salen del periodo de vacaciones vigente (del % al %). No hay arrastre al siguiente año.',
        to_char(v_period.period_start, 'DD/MM/YYYY'),
        to_char(v_period.period_end, 'DD/MM/YYYY');
    END IF;

    IF coalesce(p_row.forzar_saldo, false) IS NOT TRUE THEN
      v_used := kiosk_internal.booked_working_days(
        p_row.employee_id, 'vacaciones', ARRAY['approved'],
        v_period.period_start, v_period.period_end, p_row.id
      );
      v_pending := kiosk_internal.booked_working_days(
        p_row.employee_id, 'vacaciones', ARRAY['pending_manager', 'pending_hr'],
        v_period.period_start, v_period.period_end, p_row.id
      );
      v_available := v_period.entitled - v_used - v_pending;
      IF v_days > v_available THEN
        RAISE EXCEPTION 'El saldo no alcanza. Quedan % día(s) hábiles y esta solicitud usa %.',
          GREATEST(v_available, 0), v_days;
      END IF;
    END IF;
  END IF;

  IF v_type = 'personal' THEN
    v_day := date_trunc('month', p_row.start_date::timestamp)::date;
    v_guard := 0;
    WHILE v_day <= p_row.end_date AND v_guard < 24 LOOP
      v_year := extract(year FROM v_day)::integer;
      v_month := extract(month FROM v_day)::integer;
      v_already := kiosk_internal.booked_working_days(
        p_row.employee_id, 'personal', ARRAY['approved', 'pending_manager', 'pending_hr'],
        make_date(v_year, 1, 1), make_date(v_year, 12, 31), p_row.id
      );
      v_chunk := kiosk_internal.span_working_days(
        p_row.start_date, p_row.end_date, make_date(v_year, 1, 1), make_date(v_year, 12, 31)
      );
      IF v_already + v_chunk > 5 THEN
        RAISE EXCEPTION 'En % solo hay 5 días personales. Ya hay % y esta solicitud suma %.',
          v_year, v_already, v_chunk;
      END IF;

      v_already := kiosk_internal.booked_working_days(
        p_row.employee_id, 'personal', ARRAY['approved', 'pending_manager', 'pending_hr'],
        make_date(v_year, v_month, 1),
        (make_date(v_year, v_month, 1) + interval '1 month' - interval '1 day')::date,
        p_row.id
      );
      v_chunk := kiosk_internal.span_working_days(
        p_row.start_date, p_row.end_date,
        make_date(v_year, v_month, 1),
        (make_date(v_year, v_month, 1) + interval '1 month' - interval '1 day')::date
      );
      IF v_chunk > 0 AND v_already + v_chunk > 2 THEN
        RAISE EXCEPTION 'En ese mes solo se pueden pedir 2 días personales. Ya hay % y esta solicitud suma %.',
          v_already, v_chunk;
      END IF;
      v_day := (v_day + interval '1 month')::date;
      v_guard := v_guard + 1;
    END LOOP;

    FOR v_day IN
      SELECT g.day::date
      FROM generate_series(p_row.start_date, p_row.end_date, interval '1 day') AS g(day)
      WHERE kiosk_internal.is_working_day(g.day::date)
    LOOP
      FOREACH v_neighbor IN ARRAY ARRAY[
        kiosk_internal.shift_working_day(v_day, -1),
        kiosk_internal.shift_working_day(v_day, 1)
      ]
      LOOP
        IF EXISTS (
          SELECT 1
          FROM public.kiosk_vacation_requests other_req
          WHERE other_req.employee_id = p_row.employee_id
            AND other_req.id IS DISTINCT FROM p_row.id
            AND coalesce(other_req.request_type, 'vacaciones') = 'vacaciones'
            AND other_req.status IN ('pending_manager', 'pending_hr', 'approved')
            AND v_neighbor BETWEEN other_req.start_date AND other_req.end_date
        ) THEN
          RAISE EXCEPTION 'Un día personal no puede pegarse a vacaciones. Deja al menos un día hábil de por medio.';
        END IF;
      END LOOP;
    END LOOP;
  ELSE
    FOR v_day IN
      SELECT g.day::date
      FROM generate_series(p_row.start_date, p_row.end_date, interval '1 day') AS g(day)
      WHERE kiosk_internal.is_working_day(g.day::date)
    LOOP
      FOREACH v_neighbor IN ARRAY ARRAY[
        kiosk_internal.shift_working_day(v_day, -1),
        kiosk_internal.shift_working_day(v_day, 1)
      ]
      LOOP
        IF EXISTS (
          SELECT 1
          FROM public.kiosk_vacation_requests other_req
          WHERE other_req.employee_id = p_row.employee_id
            AND other_req.id IS DISTINCT FROM p_row.id
            AND other_req.request_type = 'personal'
            AND other_req.status IN ('pending_manager', 'pending_hr', 'approved')
            AND v_neighbor BETWEEN other_req.start_date AND other_req.end_date
        ) THEN
          RAISE EXCEPTION 'Esas vacaciones quedan pegadas a un día personal. Deja al menos un día hábil de por medio.';
        END IF;
      END LOOP;
    END LOOP;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION kiosk_internal.assert_time_off(public.kiosk_vacation_requests) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.kiosk_vacation_requests_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
#variable_conflict use_column
BEGIN
  NEW.note := nullif(regexp_replace(btrim(coalesce(NEW.note, '')), '\s+', ' ', 'g'), '');
  NEW.manager_reason := nullif(regexp_replace(btrim(coalesce(NEW.manager_reason, '')), '\s+', ' ', 'g'), '');
  NEW.hr_reason := nullif(regexp_replace(btrim(coalesce(NEW.hr_reason, '')), '\s+', ' ', 'g'), '');
  NEW.request_type := coalesce(NEW.request_type, 'vacaciones');
  NEW.forzar_saldo := coalesce(NEW.forzar_saldo, false);
  IF NEW.note IS NOT NULL AND char_length(NEW.note) > 280 THEN
    RAISE EXCEPTION 'La nota es demasiado larga';
  END IF;
  IF NEW.request_type NOT IN ('vacaciones', 'personal') THEN
    RAISE EXCEPTION 'El tipo tiene que ser vacaciones o día personal';
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
    RAISE EXCEPTION 'Esas fechas se empalman con otras vacaciones o días personales pendientes o aprobados de la misma persona';
  END IF;
  PERFORM kiosk_internal.assert_time_off(NEW);
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.kiosk_vacation_requests_guard() FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.vacation_request_create(text, date, date, text);
DROP FUNCTION IF EXISTS public.vacation_request_create(text, date, date, text, text);

CREATE FUNCTION public.vacation_request_create(
  p_pin text,
  p_start date,
  p_end date,
  p_note text,
  p_type text DEFAULT 'vacaciones'
)
RETURNS TABLE (id uuid, status text, start_date date, end_date date, note text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_emp uuid;
  v_note text;
  v_type text;
  v_new uuid;
BEGIN
  SELECT p.id INTO v_emp
  FROM kiosk_internal.employee_from_pin(p_pin) AS p;
  IF v_emp IS NULL THEN
    RAISE EXCEPTION 'PIN no encontrado';
  END IF;

  v_type := lower(btrim(coalesce(p_type, 'vacaciones')));
  IF v_type NOT IN ('vacaciones', 'personal') THEN
    RAISE EXCEPTION 'El tipo tiene que ser vacaciones o día personal';
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

  INSERT INTO public.kiosk_vacation_requests (
    employee_id, start_date, end_date, note, status, source, request_type, forzar_saldo
  ) VALUES (
    v_emp, p_start, p_end, v_note, 'pending_manager', 'solicitud', v_type, false
  )
  RETURNING public.kiosk_vacation_requests.id INTO v_new;

  RETURN QUERY
  SELECT v_new, 'pending_manager'::text, p_start, p_end, v_note;
END;
$$;

DROP FUNCTION IF EXISTS public.vacation_portal(text);

CREATE FUNCTION public.vacation_portal(p_pin text)
RETURNS TABLE (
  employee_id uuid,
  name text,
  manager_name text,
  requests jsonb,
  team jsonb,
  direct_reports integer,
  balance jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_emp uuid;
  v_name text;
  v_manager uuid;
  v_manager_name text;
  v_requests jsonb;
  v_team jsonb;
  v_reports integer;
  v_balance jsonb;
BEGIN
  SELECT p.id, p.name, p.manager_id
    INTO v_emp, v_name, v_manager
  FROM kiosk_internal.employee_from_pin(p_pin) AS p;
  IF v_emp IS NULL THEN
    RAISE EXCEPTION 'PIN no encontrado';
  END IF;

  SELECT m.name INTO v_manager_name
  FROM public.kiosk_employees m
  WHERE m.id = v_manager;

  v_balance := kiosk_internal.balance_json(v_emp, NULL);

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'start_date', r.start_date,
    'end_date', r.end_date,
    'note', r.note,
    'status', r.status,
    'source', r.source,
    'request_type', coalesce(r.request_type, 'vacaciones'),
    'manager_name', r.manager_name,
    'manager_reason', r.manager_reason,
    'hr_reason', r.hr_reason,
    'created_at', r.created_at
  ) ORDER BY r.start_date DESC, r.created_at DESC), '[]'::jsonb)
    INTO v_requests
  FROM public.kiosk_vacation_requests r
  WHERE r.employee_id = v_emp;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'employee_id', r.employee_id,
    'employee_name', e.name,
    'start_date', r.start_date,
    'end_date', r.end_date,
    'note', r.note,
    'status', r.status,
    'request_type', coalesce(r.request_type, 'vacaciones'),
    'balance', kiosk_internal.balance_json(e.id, NULL),
    'created_at', r.created_at
  ) ORDER BY r.created_at DESC), '[]'::jsonb)
    INTO v_team
  FROM public.kiosk_vacation_requests r
  JOIN public.kiosk_employees e ON e.id = r.employee_id
  WHERE e.manager_id = v_emp
    AND r.status = 'pending_manager';

  SELECT count(*)::integer INTO v_reports
  FROM public.kiosk_employees e
  WHERE e.manager_id = v_emp;

  RETURN QUERY
  SELECT v_emp, v_name, v_manager_name, v_requests, v_team, v_reports, v_balance;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_fecha_ingreso(
  p_code text,
  p_employee_id uuid,
  p_fecha date
)
RETURNS date
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;
  IF p_fecha IS NOT NULL AND (p_fecha < DATE '1970-01-01' OR p_fecha > (now() AT TIME ZONE 'America/Mexico_City')::date) THEN
    RAISE EXCEPTION 'La fecha de ingreso tiene que estar entre 1970 y hoy';
  END IF;
  UPDATE public.kiosk_employees e
     SET fecha_ingreso = p_fecha
   WHERE e.id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Empleado no encontrado';
  END IF;
  RETURN p_fecha;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_employee_balance(p_code text, p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.kiosk_employees e WHERE e.id = p_employee_id) THEN
    RAISE EXCEPTION 'Empleado no encontrado';
  END IF;
  RETURN kiosk_internal.balance_json(p_employee_id, NULL);
END;
$$;

DROP FUNCTION IF EXISTS public.admin_list_managers(text);

CREATE FUNCTION public.admin_list_managers(p_code text)
RETURNS TABLE (id uuid, name text, manager_id uuid, manager_name text, fecha_ingreso date)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;

  RETURN QUERY
  SELECT e.id, e.name, e.manager_id, m.name, e.fecha_ingreso
  FROM public.kiosk_employees e
  LEFT JOIN public.kiosk_employees m ON m.id = e.manager_id
  ORDER BY e.name;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_save_vacation(text, uuid, uuid, date, date, text);
DROP FUNCTION IF EXISTS public.admin_save_vacation(text, uuid, uuid, date, date, text, text, boolean);

CREATE FUNCTION public.admin_save_vacation(
  p_code text,
  p_id uuid,
  p_employee_id uuid,
  p_start date,
  p_end date,
  p_note text,
  p_type text DEFAULT 'vacaciones',
  p_forzar boolean DEFAULT false
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
#variable_conflict use_column
DECLARE
  v_note text;
  v_type text;
  v_id uuid;
  v_name text;
  v_status text;
  v_source text;
  v_emp uuid;
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;

  v_type := lower(btrim(coalesce(p_type, 'vacaciones')));
  IF v_type NOT IN ('vacaciones', 'personal') THEN
    RAISE EXCEPTION 'El tipo tiene que ser vacaciones o día personal';
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

  IF p_id IS NULL THEN
    SELECT e.name INTO v_name
    FROM public.kiosk_employees e
    WHERE e.id = p_employee_id;
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'Empleado no encontrado';
    END IF;

    INSERT INTO public.kiosk_vacation_requests (
      employee_id, start_date, end_date, note, status, source,
      request_type, forzar_saldo,
      hr_decision, hr_decided_at, hr_actor, hr_reason
    ) VALUES (
      p_employee_id, p_start, p_end, v_note, 'approved', 'rh_directa',
      v_type, coalesce(p_forzar, false) AND v_type = 'vacaciones',
      'approved', now(), 'RH (carga directa)',
      CASE
        WHEN coalesce(p_forzar, false) AND v_type = 'vacaciones'
          THEN 'Cargada directo por RH, forzando el saldo de vacaciones.'
        ELSE 'Cargada directo por RH, sin las dos aprobaciones.'
      END
    )
    RETURNING public.kiosk_vacation_requests.id INTO v_id;
    v_status := 'approved';
    v_source := 'rh_directa';
    v_emp := p_employee_id;
  ELSE
    UPDATE public.kiosk_vacation_requests v
       SET start_date = p_start,
           end_date = p_end,
           note = v_note,
           request_type = v_type,
           forzar_saldo = coalesce(p_forzar, false) AND v_type = 'vacaciones',
           employee_id = COALESCE(p_employee_id, v.employee_id)
     WHERE v.id = p_id
       AND v.status <> 'cancelled'
    RETURNING v.id, v.status, v.source, v.employee_id
      INTO v_id, v_status, v_source, v_emp;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'Esas vacaciones no se pueden editar. Si están canceladas, carga unas nuevas.';
    END IF;
    SELECT e.name INTO v_name
    FROM public.kiosk_employees e
    WHERE e.id = v_emp;
  END IF;

  RETURN QUERY
  SELECT v_id, v_emp, v_name, p_start, p_end, v_note, v_status, v_source;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_list_vacations(text);

CREATE FUNCTION public.admin_list_vacations(p_code text)
RETURNS TABLE (
  id uuid,
  employee_id uuid,
  employee_name text,
  start_date date,
  end_date date,
  note text,
  status text,
  source text,
  request_type text,
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
#variable_conflict use_column
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;

  RETURN QUERY
  SELECT
    v.id, v.employee_id, e.name, v.start_date, v.end_date, v.note,
    v.status, v.source, coalesce(v.request_type, 'vacaciones'),
    v.manager_name, v.manager_decision, v.manager_reason,
    v.manager_decided_at, v.hr_decision, v.hr_reason, v.hr_decided_at, v.hr_actor
  FROM public.kiosk_vacation_requests v
  JOIN public.kiosk_employees e ON e.id = v.employee_id
  ORDER BY v.start_date, e.name;
END;
$$;

REVOKE ALL ON FUNCTION public.vacation_request_create(text, date, date, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vacation_portal(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_fecha_ingreso(text, uuid, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_employee_balance(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_managers(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_save_vacation(text, uuid, uuid, date, date, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_list_vacations(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.vacation_request_create(text, date, date, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vacation_portal(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_fecha_ingreso(text, uuid, date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_employee_balance(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_managers(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_vacation(text, uuid, uuid, date, date, text, text, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_vacations(text) TO anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.vacation_request_create(text, date, date, text, text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.vacation_portal(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_set_fecha_ingreso(text, uuid, date) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_employee_balance(text, uuid) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_list_managers(text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_save_vacation(text, uuid, uuid, date, date, text, text, boolean) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_list_vacations(text) TO service_role';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

-- Verificación. anio_1 = 12, anio_2 = 14, anio_5 = 20, anio_6 = 22, anio_11 = 24, anio_31 = 32.
SELECT kiosk_internal.lft_vacation_days(1) AS anio_1,
       kiosk_internal.lft_vacation_days(2) AS anio_2,
       kiosk_internal.lft_vacation_days(5) AS anio_5,
       kiosk_internal.lft_vacation_days(6) AS anio_6,
       kiosk_internal.lft_vacation_days(10) AS anio_10,
       kiosk_internal.lft_vacation_days(11) AS anio_11,
       kiosk_internal.lft_vacation_days(31) AS anio_31,
       kiosk_internal.lft_vacation_days(0) AS antes_del_aniversario;
