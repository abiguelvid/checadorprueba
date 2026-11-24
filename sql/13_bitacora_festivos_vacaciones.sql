-- Checador · paso 13
-- La solicitud de vacaciones falla con "Tabla fuera de la bitácora".
--
-- NO se ejecutó contra la base de producción. Córralo en el SQL Editor
-- después del 10 (y del 12, si ya se corrió). Se puede correr más de una vez.
-- No borra solicitudes, festivos, empleados ni checadas. No apaga la bitácora.
-- No toca la ubicación.
--
-- Causa: sql/06 solo deja auditar kiosk_attendance y kiosk_employees.
-- La frase está en kiosk_internal.write_kiosk_audit, no en la pantalla.
-- sql/10 engancha un trigger de bitácora en kiosk_vacation_requests y amplía
-- el CHECK de la tabla, pero no cambia esa función. El insert de la solicitud
-- dispara el trigger, la función rechaza la tabla y Postgres deshace todo.
-- Por eso no queda la solicitud.
-- Lo mismo le pasaría a cancelar, a la aprobación del manager, a la de RH
-- y a la carga directa: todas escriben en kiosk_vacation_requests.
-- Asignar manager escribe en kiosk_employees, que ya estaba permitida.
-- Los festivos no tenían trigger; este archivo se los pone y los admite,
-- para que un alta de festivo no falle en el siguiente paso.
--
-- Al final hay una consulta. acepta_solicitudes y acepta_festivos tienen
-- que ser true.

CREATE OR REPLACE FUNCTION kiosk_internal.write_kiosk_audit(
  p_table text,
  p_record_id text,
  p_action text,
  p_old jsonb,
  p_new jsonb,
  p_actor_role text,
  p_actor_uid uuid,
  p_db_role text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_prev text;
  v_at timestamptz := clock_timestamp();
  v_role text := nullif(btrim(coalesce(p_actor_role, '')), '');
  v_db text := nullif(btrim(coalesce(p_db_role, '')), '');
  v_hash text;
  v_genesis constant text := '0babb132451e906d8a2aa08a94a3f40c8e9887ec79983653ade2050cf9dc7e6a';
BEGIN
  IF p_table NOT IN ('kiosk_attendance', 'kiosk_employees', 'kiosk_vacation_requests', 'kiosk_holidays') THEN
    RAISE EXCEPTION 'Tabla fuera de la bitácora';
  END IF;
  IF p_action NOT IN ('INSERT', 'UPDATE', 'DELETE', 'BASELINE') THEN
    RAISE EXCEPTION 'Acción fuera de la bitácora';
  END IF;
  IF v_db IS NULL THEN
    v_db := current_user;
  END IF;
  IF v_role IS NULL THEN
    v_role := v_db;
  END IF;

  PERFORM pg_advisory_xact_lock(872341001);

  SELECT l.row_hash
    INTO v_prev
  FROM public.kiosk_audit_log AS l
  ORDER BY l.id DESC
  LIMIT 1;

  IF v_prev IS NULL THEN
    v_prev := v_genesis;
  END IF;

  v_hash := kiosk_internal.kiosk_audit_hash(
    p_table, p_record_id, p_action, p_old, p_new, v_role, p_actor_uid, v_db, v_at, v_prev
  );

  INSERT INTO public.kiosk_audit_log (
    logged_at, table_name, record_id, action, old_row, new_row,
    actor_role, actor_uid, db_role, prev_hash, row_hash
  ) VALUES (
    v_at, p_table, coalesce(p_record_id, ''), p_action, p_old, p_new,
    v_role, p_actor_uid, v_db, v_prev, v_hash
  );
END;
$$;

DO $widen$
BEGIN
  IF to_regclass('public.kiosk_audit_log') IS NULL THEN
    RAISE EXCEPTION 'Falta la bitácora. Corre sql/06_bitacora_auditoria.sql antes de este archivo.';
  END IF;
  IF to_regclass('public.kiosk_vacation_requests') IS NULL
     OR to_regclass('public.kiosk_holidays') IS NULL THEN
    RAISE EXCEPTION 'Faltan festivos o vacaciones. Corre sql/10_festivos_y_vacaciones.sql antes de este archivo.';
  END IF;
  IF to_regprocedure('kiosk_internal.audit_kiosk_change()') IS NULL THEN
    RAISE EXCEPTION 'Falta el trigger de la bitácora. Corre sql/06_bitacora_auditoria.sql antes de este archivo.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'kiosk_audit_log_table_chk'
  ) THEN
    ALTER TABLE public.kiosk_audit_log DROP CONSTRAINT kiosk_audit_log_table_chk;
  END IF;
  ALTER TABLE public.kiosk_audit_log
    ADD CONSTRAINT kiosk_audit_log_table_chk
    CHECK (table_name IN ('kiosk_attendance', 'kiosk_employees', 'kiosk_vacation_requests', 'kiosk_holidays'));

  DROP TRIGGER IF EXISTS kiosk_vacation_requests_audit ON public.kiosk_vacation_requests;
  CREATE TRIGGER kiosk_vacation_requests_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.kiosk_vacation_requests
    FOR EACH ROW
    EXECUTE FUNCTION kiosk_internal.audit_kiosk_change();

  DROP TRIGGER IF EXISTS kiosk_holidays_audit ON public.kiosk_holidays;
  CREATE TRIGGER kiosk_holidays_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.kiosk_holidays
    FOR EACH ROW
    EXECUTE FUNCTION kiosk_internal.audit_kiosk_change();
END
$widen$;

-- Lo que ya existía entra como registro inicial. No se duplica si se corre otra vez.
DO $baseline$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT v.id::text AS record_id, to_jsonb(v) AS row_data
    FROM public.kiosk_vacation_requests AS v
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.kiosk_audit_log AS l
      WHERE l.table_name = 'kiosk_vacation_requests'
        AND l.record_id = v.id::text
    )
    ORDER BY v.created_at, v.id
  LOOP
    PERFORM kiosk_internal.write_kiosk_audit(
      'kiosk_vacation_requests', r.record_id, 'BASELINE', NULL, r.row_data,
      current_user, NULL, current_user
    );
  END LOOP;

  FOR r IN
    SELECT h.id::text AS record_id, to_jsonb(h) AS row_data
    FROM public.kiosk_holidays AS h
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.kiosk_audit_log AS l
      WHERE l.table_name = 'kiosk_holidays'
        AND l.record_id = h.id::text
    )
    ORDER BY h.holiday_date, h.id
  LOOP
    PERFORM kiosk_internal.write_kiosk_audit(
      'kiosk_holidays', r.record_id, 'BASELINE', NULL, r.row_data,
      current_user, NULL, current_user
    );
  END LOOP;
END
$baseline$;

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
#variable_conflict use_column
BEGIN
  IF to_regclass('public.kiosk_audit_log') IS NULL THEN
    RAISE EXCEPTION 'Falta la bitácora. Corre sql/06_bitacora_auditoria.sql en Supabase.';
  END IF;
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;
  IF p_table NOT IN ('kiosk_attendance', 'kiosk_employees', 'kiosk_vacation_requests', 'kiosk_holidays') THEN
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

-- Verificación. acepta_solicitudes y acepta_festivos tienen que ser true.
SELECT
  (p.prosrc LIKE '%kiosk_vacation_requests%') AS acepta_solicitudes,
  (p.prosrc LIKE '%kiosk_holidays%') AS acepta_festivos,
  (pg_get_constraintdef(c.oid) LIKE '%kiosk_vacation_requests%') AS check_solicitudes,
  (pg_get_constraintdef(c.oid) LIKE '%kiosk_holidays%') AS check_festivos
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_constraint c ON c.conname = 'kiosk_audit_log_table_chk'
WHERE n.nspname = 'kiosk_internal'
  AND p.proname = 'write_kiosk_audit';
