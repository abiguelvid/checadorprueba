-- Checador · paso 6
-- Bitácora de auditoría para asistencia y empleados.
--
-- NO se ejecutó contra la base. Lo corre a mano quien administra Supabase,
-- en el SQL Editor, después de leerlo. Se puede correr más de una vez.
-- No borra la bitácora ni los registros.
--
-- Orden:
--   1. sql/01 y sql/02 ya están aplicados.
--   2. sql/04_foto_kiosk_attendance.sql (columna photo_path, bucket, políticas).
--   3. ESTE archivo.
--   4. sql/05_retencion_fotos_asistencia.sql sigue siendo opcional y no está activo.
--   5. sql/03_seguridad_pin_y_admin.sql sigue para más adelante.
--
-- Qué hace:
--   * Columna kiosk_attendance.photo_sha256: huella SHA-256 del JPEG.
--     Si alguien reemplaza el archivo en Storage, la huella deja de coincidir.
--   * Tabla public.kiosk_audit_log. Cada INSERT, UPDATE y DELETE de
--     kiosk_attendance y kiosk_employees deja una fila (valor anterior,
--     valor nuevo, rol de la petición si hay JWT, rol de la base y la hora
--     del servidor). El trigger corre también si el cambio sale del SQL
--     Editor o de la API.
--   * Los registros que ya existían reciben una entrada BASELINE: es la foto
--     inicial del renglón al momento de correr este archivo. Lo anterior a
--     eso no está en la bitácora.
--   * Cada entrada guarda el hash de la anterior. La primera usa el hash de
--     la frase kiosk-audit-genesis-v1.
--   * La app no puede corregir ni borrar la bitácora: no hay permisos de
--     UPDATE/DELETE y un trigger rechaza esos cambios, también TRUNCATE.
--   * admin_list_kiosk_audit y admin_verify_kiosk_audit leen la bitácora
--     con el código de la admin. La anon key no puede hacer SELECT directo.
--
-- Límites, en corto:
--   Un superusuario (postgres o supabase_admin) puede apagar los triggers
--   y entonces sí puede cambiar o reescribir la bitácora. Mientras los
--   triggers sigan activos, ni ese rol pasa el rechazo de UPDATE/DELETE.
--   Si reescribe la cadena y recalcula los hashes, la verificación interna
--   vuelve a decir que está íntegra. Por eso hay que copiar el último hash
--   (tip_hash) fuera de Supabase cada tanto. La función de verificación
--   también compara cada renglón vivo con su última entrada: un cambio hecho
--   con el trigger de auditoría apagado no coincide.
--
-- Cómo anclar el hash fuera:
--   select * from public.admin_verify_kiosk_audit('tu-codigo');
--   Guarda tip_hash en un lugar que esta base no pueda tocar: un correo,
--   otro sistema, o un commit en un repositorio al que no tenga acceso
--   quien administra Supabase. Si el hash guardado no es el de hoy, la
--   historia se reescribió.

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

ALTER TABLE public.kiosk_attendance
  ADD COLUMN IF NOT EXISTS photo_sha256 text;

COMMENT ON COLUMN public.kiosk_attendance.photo_sha256 IS
  'SHA-256 hex del JPEG guardado en photo_path. NULL en registros viejos. Sirve para notar si el archivo se reemplazó.';

ALTER TABLE public.kiosk_attendance
  DROP CONSTRAINT IF EXISTS kiosk_attendance_photo_sha256_format;

ALTER TABLE public.kiosk_attendance
  ADD CONSTRAINT kiosk_attendance_photo_sha256_format
  CHECK (photo_sha256 IS NULL OR photo_sha256 ~ '^[0-9a-f]{64}$');

CREATE SCHEMA IF NOT EXISTS kiosk_internal;
GRANT USAGE ON SCHEMA kiosk_internal TO anon, authenticated;

CREATE TABLE IF NOT EXISTS public.kiosk_audit_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  logged_at timestamptz NOT NULL,
  table_name text NOT NULL,
  record_id text NOT NULL,
  action text NOT NULL,
  old_row jsonb,
  new_row jsonb,
  actor_role text,
  actor_uid uuid,
  db_role text NOT NULL,
  prev_hash text NOT NULL,
  row_hash text NOT NULL,
  CONSTRAINT kiosk_audit_log_action_chk
    CHECK (action IN ('INSERT', 'UPDATE', 'DELETE', 'BASELINE')),
  CONSTRAINT kiosk_audit_log_hash_chk
    CHECK (prev_hash ~ '^[0-9a-f]{64}$' AND row_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT kiosk_audit_log_table_chk
    CHECK (table_name IN ('kiosk_attendance', 'kiosk_employees', 'kiosk_vacation_requests', 'kiosk_holidays'))
);

COMMENT ON TABLE public.kiosk_audit_log IS
  'Bitácora append-only. No se edita ni se borra. Cada fila incluye el hash de la anterior.';

CREATE INDEX IF NOT EXISTS kiosk_audit_log_record_idx
  ON public.kiosk_audit_log (table_name, record_id, id DESC);

-- El texto que se hashea no se puede cambiar: si cambia, la cadena vieja deja de verificar.
CREATE OR REPLACE FUNCTION kiosk_internal.kiosk_audit_hash(
  p_table text,
  p_record_id text,
  p_action text,
  p_old jsonb,
  p_new jsonb,
  p_actor_role text,
  p_actor_uid uuid,
  p_db_role text,
  p_logged_at timestamptz,
  p_prev_hash text
)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT encode(
    extensions.digest(
      convert_to(
        coalesce(p_table, '') || '|' ||
        coalesce(p_record_id, '') || '|' ||
        coalesce(p_action, '') || '|' ||
        coalesce(p_old::text, 'null') || '|' ||
        coalesce(p_new::text, 'null') || '|' ||
        coalesce(p_actor_role, '') || '|' ||
        coalesce(p_actor_uid::text, '') || '|' ||
        coalesce(p_db_role, '') || '|' ||
        to_char(p_logged_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || '|' ||
        coalesce(p_prev_hash, ''),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

-- La anon key no tiene permiso sobre esta función. La usa el trigger
-- (vía append_kiosk_audit) y el baseline de este archivo.
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

-- Si la tabla ya existía, el CREATE de arriba no cambia el CHECK.
DO $$
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
    CHECK (table_name IN ('kiosk_attendance', 'kiosk_employees', 'kiosk_vacation_requests', 'kiosk_holidays'));
END $$;

-- Puerta para el trigger. Una llamada suelta de la API no trae profundidad de trigger.
CREATE OR REPLACE FUNCTION kiosk_internal.append_kiosk_audit(
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
BEGIN
  IF pg_trigger_depth() < 1 THEN
    RAISE EXCEPTION 'La bitácora solo se escribe desde el trigger' USING ERRCODE = '42501';
  END IF;
  PERFORM kiosk_internal.write_kiosk_audit(
    p_table, p_record_id, p_action, p_old, p_new, p_actor_role, p_actor_uid, p_db_role
  );
END;
$$;

-- Corre como quien hizo el cambio, para guardar su rol. La escritura de la
-- bitácora la hace write_kiosk_audit, que sí es security definer.
CREATE OR REPLACE FUNCTION kiosk_internal.audit_kiosk_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_id text;
  v_old jsonb;
  v_new jsonb;
  v_role text;
  v_uid uuid;
BEGIN
  IF TG_OP IS NULL THEN
    RAISE EXCEPTION 'La bitácora solo se escribe desde el trigger' USING ERRCODE = '42501';
  END IF;

  BEGIN
    v_uid := auth.uid();
  EXCEPTION
    WHEN undefined_function OR invalid_schema_name THEN
      v_uid := NULL;
  END;

  BEGIN
    v_role := auth.role();
  EXCEPTION
    WHEN undefined_function OR invalid_schema_name THEN
      v_role := NULL;
  END;

  IF v_role IS NULL OR btrim(v_role) = '' THEN
    v_role := nullif(current_setting('request.jwt.claim.role', true), '');
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_id := OLD.id::text;
    v_old := to_jsonb(OLD);
    v_new := NULL;
  ELSE
    v_id := NEW.id::text;
    v_new := to_jsonb(NEW);
    v_old := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE NULL END;
  END IF;

  PERFORM kiosk_internal.append_kiosk_audit(
    TG_TABLE_NAME, v_id, TG_OP, v_old, v_new, v_role, v_uid, current_user
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION kiosk_internal.reject_kiosk_audit_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'La bitácora no se puede modificar ni borrar.'
    USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS kiosk_attendance_audit ON public.kiosk_attendance;
CREATE TRIGGER kiosk_attendance_audit
AFTER INSERT OR UPDATE OR DELETE ON public.kiosk_attendance
FOR EACH ROW
EXECUTE FUNCTION kiosk_internal.audit_kiosk_change();

DROP TRIGGER IF EXISTS kiosk_employees_audit ON public.kiosk_employees;
CREATE TRIGGER kiosk_employees_audit
AFTER INSERT OR UPDATE OR DELETE ON public.kiosk_employees
FOR EACH ROW
EXECUTE FUNCTION kiosk_internal.audit_kiosk_change();

DROP TRIGGER IF EXISTS kiosk_audit_log_no_change ON public.kiosk_audit_log;
CREATE TRIGGER kiosk_audit_log_no_change
BEFORE UPDATE OR DELETE ON public.kiosk_audit_log
FOR EACH ROW
EXECUTE FUNCTION kiosk_internal.reject_kiosk_audit_change();

DROP TRIGGER IF EXISTS kiosk_audit_log_no_truncate ON public.kiosk_audit_log;
CREATE TRIGGER kiosk_audit_log_no_truncate
BEFORE TRUNCATE ON public.kiosk_audit_log
FOR EACH STATEMENT
EXECUTE FUNCTION kiosk_internal.reject_kiosk_audit_change();

ALTER TABLE public.kiosk_audit_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.kiosk_audit_log FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION kiosk_internal.kiosk_audit_hash(text, text, text, jsonb, jsonb, text, uuid, text, timestamptz, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION kiosk_internal.write_kiosk_audit(text, text, text, jsonb, jsonb, text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION kiosk_internal.append_kiosk_audit(text, text, text, jsonb, jsonb, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION kiosk_internal.audit_kiosk_change() FROM PUBLIC;
REVOKE ALL ON FUNCTION kiosk_internal.reject_kiosk_audit_change() FROM PUBLIC;
-- Quien dispara el cambio tiene que poder ejecutar el trigger.
-- append rechaza llamadas que no vengan de un trigger.
GRANT EXECUTE ON FUNCTION kiosk_internal.append_kiosk_audit(text, text, text, jsonb, jsonb, text, uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kiosk_internal.audit_kiosk_change() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kiosk_internal.reject_kiosk_audit_change() TO anon, authenticated;

-- Foto inicial de los renglones que todavía no tienen bitácora.
-- Empleados primero, por id; después asistencias, por fecha e id.
DO $baseline$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT e.id::text AS record_id, to_jsonb(e) AS row_data
    FROM public.kiosk_employees AS e
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.kiosk_audit_log AS l
      WHERE l.table_name = 'kiosk_employees'
        AND l.record_id = e.id::text
    )
    ORDER BY e.id
  LOOP
    PERFORM kiosk_internal.write_kiosk_audit(
      'kiosk_employees', r.record_id, 'BASELINE', NULL, r.row_data,
      current_user, NULL, current_user
    );
  END LOOP;

  FOR r IN
    SELECT a.id::text AS record_id, to_jsonb(a) AS row_data
    FROM public.kiosk_attendance AS a
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.kiosk_audit_log AS l
      WHERE l.table_name = 'kiosk_attendance'
        AND l.record_id = a.id::text
    )
    ORDER BY a."timestamp", a.id
  LOOP
    PERFORM kiosk_internal.write_kiosk_audit(
      'kiosk_attendance', r.record_id, 'BASELINE', NULL, r.row_data,
      current_user, NULL, current_user
    );
  END LOOP;
END
$baseline$;

CREATE OR REPLACE FUNCTION kiosk_internal.verify_kiosk_audit()
RETURNS TABLE (
  ok boolean,
  checked_count bigint,
  broken_id bigint,
  tip_hash text,
  snapshot_mismatches bigint,
  detail text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_prev text := '0babb132451e906d8a2aa08a94a3f40c8e9887ec79983653ade2050cf9dc7e6a';
  v_calc text;
  v_n bigint := 0;
  v_bad bigint := 0;
  v_tip text := v_prev;
BEGIN
  FOR r IN
    SELECT *
    FROM public.kiosk_audit_log
    ORDER BY id
  LOOP
    v_n := v_n + 1;
    IF r.prev_hash IS DISTINCT FROM v_prev THEN
      ok := false;
      checked_count := v_n;
      broken_id := r.id;
      tip_hash := NULL;
      snapshot_mismatches := 0;
      detail := 'La cadena se rompió en la entrada ' || r.id::text || '. El eslabón anterior no coincide.';
      RETURN NEXT;
      RETURN;
    END IF;

    v_calc := kiosk_internal.kiosk_audit_hash(
      r.table_name, r.record_id, r.action, r.old_row, r.new_row,
      r.actor_role, r.actor_uid, r.db_role, r.logged_at, r.prev_hash
    );
    IF r.row_hash IS DISTINCT FROM v_calc THEN
      ok := false;
      checked_count := v_n;
      broken_id := r.id;
      tip_hash := NULL;
      snapshot_mismatches := 0;
      detail := 'El contenido de la entrada ' || r.id::text || ' no coincide con su hash.';
      RETURN NEXT;
      RETURN;
    END IF;
    v_prev := r.row_hash;
    v_tip := r.row_hash;
  END LOOP;

  SELECT count(*)
    INTO v_bad
  FROM (
    SELECT a.id::text
    FROM public.kiosk_attendance AS a
    LEFT JOIN LATERAL (
      SELECT l.action, l.new_row
      FROM public.kiosk_audit_log AS l
      WHERE l.table_name = 'kiosk_attendance'
        AND l.record_id = a.id::text
      ORDER BY l.id DESC
      LIMIT 1
    ) AS last ON true
    WHERE last.action IS NULL
       OR last.action = 'DELETE'
       OR last.new_row IS DISTINCT FROM to_jsonb(a)
    UNION ALL
    SELECT e.id::text
    FROM public.kiosk_employees AS e
    LEFT JOIN LATERAL (
      SELECT l.action, l.new_row
      FROM public.kiosk_audit_log AS l
      WHERE l.table_name = 'kiosk_employees'
        AND l.record_id = e.id::text
      ORDER BY l.id DESC
      LIMIT 1
    ) AS last ON true
    WHERE last.action IS NULL
       OR last.action = 'DELETE'
       OR last.new_row IS DISTINCT FROM to_jsonb(e)
  ) AS bad;

  ok := v_bad = 0;
  checked_count := v_n;
  broken_id := NULL;
  tip_hash := v_tip;
  snapshot_mismatches := v_bad;
  IF v_bad = 0 THEN
    detail := 'La bitácora está íntegra. ' || v_n::text || ' entradas.';
  ELSE
    detail := 'La cadena de hashes está íntegra, pero ' || v_bad::text
      || ' registros no coinciden con su última entrada. Pudo haber un cambio con los triggers apagados.';
  END IF;
  RETURN NEXT;
END;
$$;

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
  -- Mismo código de respaldo que la admin usa antes del paso 3.
  RETURN p_code IS NOT NULL AND p_code = 'nfg-rh';
END;
$$;

REVOKE ALL ON FUNCTION kiosk_internal.verify_kiosk_audit() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION kiosk_internal.admin_code_ok(text) FROM PUBLIC, anon, authenticated;

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
SET search_path = ''
AS $$
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;
  IF p_table NOT IN ('kiosk_attendance', 'kiosk_employees') THEN
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

CREATE OR REPLACE FUNCTION public.admin_verify_kiosk_audit(p_code text)
RETURNS TABLE (
  ok boolean,
  checked_count bigint,
  broken_id bigint,
  tip_hash text,
  snapshot_mismatches bigint,
  detail text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT kiosk_internal.admin_code_ok(p_code) THEN
    RAISE EXCEPTION 'Código de acceso incorrecto' USING ERRCODE = '28000';
  END IF;

  RETURN QUERY
  SELECT v.ok, v.checked_count, v.broken_id, v.tip_hash, v.snapshot_mismatches, v.detail
  FROM kiosk_internal.verify_kiosk_audit() AS v;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_kiosk_audit(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_verify_kiosk_audit(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_kiosk_audit(text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_verify_kiosk_audit(text) TO anon, authenticated;

DO $grant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_list_kiosk_audit(text, text, text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_verify_kiosk_audit(text) TO service_role';
  END IF;
END
$grant$;

-- Deja la función de registro pidiendo también la huella.
-- Si el 04 de este mismo cambio ya la dejó así, esto solo la vuelve a crear.

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
