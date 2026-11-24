-- Checador · paso 11
-- Corrige "column reference \"id\" is ambiguous" al solicitar vacaciones,
-- al guardar un festivo y al cargar vacaciones directo desde RH.
--
-- NO se ejecutó contra la base de producción. Córralo en el SQL Editor
-- después de sql/10_festivos_y_vacaciones.sql, si ese archivo ya se aplicó
-- con las funciones viejas. Se puede correr más de una vez.
-- Solo reemplaza tres funciones. No borra empleados, festivos, solicitudes
-- ni checadas. No toca la ubicación.
--
-- Causa: esas funciones declaran una columna de salida llamada id
-- (RETURNS TABLE) y a la vez hacen RETURNING id. Postgres no sabe si id
-- es la columna de la tabla o la variable de salida.
-- El arreglo califica el nombre: RETURNING public.<tabla>.id.
-- Las otras funciones del paso 10 ya califican sus columnas o no devuelven
-- una columna id, y no fallan por esto.
--
-- Una instalación nueva puede usar solo el sql/10 ya corregido. Correr
-- este archivo encima tampoco cambia datos.

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

