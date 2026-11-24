const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const DB = 'checador_fn_test';
const LEON = '11111111-1111-4111-8111-111111111111';
const ABRAHAM = '22222222-2222-4222-8222-222222222222';

function hasLocalPostgres() {
  try {
    execFileSync('sudo', ['-u', 'postgres', 'psql', '-d', 'postgres', '-c', 'SELECT 1'], { stdio: 'ignore' });
    return true;
  } catch (_) {
    return false;
  }
}

function psql(database, args, input) {
  return execFileSync('sudo', ['-u', 'postgres', 'psql', '-d', database, '-v', 'ON_ERROR_STOP=1', ...args], {
    encoding: 'utf8',
    input: input || null
  });
}

function psqlFile(database, file) {
  return psql(database, ['-f', file]);
}

test('las funciones del SQL 10 y 11 no chocan con la columna id', { skip: hasLocalPostgres() ? false : 'no hay Postgres local' }, () => {
  psql('postgres', ['-c', `DROP DATABASE IF EXISTS ${DB}`]);
  psql('postgres', ['-c', `CREATE DATABASE ${DB}`]);
  psql(DB, ['-c', `
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        CREATE ROLE service_role NOLOGIN;
      END IF;
    END $$;
    CREATE TABLE public.kiosk_employees (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      name text NOT NULL,
      pin text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now()
    );
    INSERT INTO public.kiosk_employees (id, name, pin) VALUES
      ('${LEON}', 'LEON ALBARRAN MENA', '1111'),
      ('${ABRAHAM}', 'ABRAHAM DEL RIO', '2222');
  `]);

  const root = __dirname;
  psqlFile(DB, path.join(root, 'sql/10_festivos_y_vacaciones.sql'));

  psql(DB, ['-c', `
    SELECT public.admin_set_manager('nfg-rh', '${ABRAHAM}', '${LEON}');
    INSERT INTO public.kiosk_vacation_requests (
      employee_id, start_date, end_date, note, status, source
    ) VALUES (
      '${ABRAHAM}', DATE '2026-01-02', DATE '2026-01-02', 'ya estaba', 'approved', 'rh_directa'
    );
  `]);
  const before = psql(DB, ['-tAc', 'SELECT count(*) FROM public.kiosk_vacation_requests']);

  const broken = `
    CREATE OR REPLACE FUNCTION public.vacation_request_create(
      p_pin text, p_start date, p_end date, p_note text
    )
    RETURNS TABLE (id uuid, status text, start_date date, end_date date, note text)
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
    AS $fn$
    DECLARE
      v_id uuid;
      v_new uuid;
    BEGIN
      SELECT p.id INTO v_id FROM kiosk_internal.employee_from_pin(p_pin) AS p;
      INSERT INTO public.kiosk_vacation_requests (
        employee_id, start_date, end_date, note, status, source
      ) VALUES (
        v_id, p_start, p_end, p_note, 'pending_manager', 'solicitud'
      )
      RETURNING id INTO v_new;
      RETURN QUERY SELECT v_new, 'pending_manager'::text, p_start, p_end, p_note;
    END
    $fn$;
  `;
  psql(DB, ['-c', broken]);
  psql(DB, ['-c', broken.replace(
    'p_pin text, p_start date, p_end date, p_note text',
    'p_pin text, p_start text, p_end text, p_note text'
  ).replace(
    "RETURNS TABLE (id uuid, status text, start_date date, end_date date, note text)",
    "RETURNS TABLE (id uuid, status text, start_date text, end_date text, note text)"
  )]);
  let ambiguous = '';
  try {
    psql(DB, ['-c', `SELECT * FROM public.vacation_request_create('2222', DATE '2026-12-15', DATE '2026-12-17', 'nota')`]);
  } catch (err) {
    ambiguous = String(err.stderr || err.stdout || err.message);
  }
  assert.match(ambiguous, /column reference "id" is ambiguous/);

  psqlFile(DB, path.join(root, 'sql/12_id_sin_ambiguedad.sql'));
  const signatures = psql(DB, ['-tAc', `
    SELECT pg_get_function_identity_arguments(p.oid)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'vacation_request_create'
    ORDER BY 1
  `]).trim();
  assert.equal(signatures, 'p_pin text, p_start date, p_end date, p_note text');
  const flags = psql(DB, ['-tAc', `
    SELECT (p.prosrc LIKE '%#variable_conflict use_column%')::text
      || '|' || (p.prosrc LIKE '%RETURNING id%')::text
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'vacation_request_create'
  `]).trim();
  assert.equal(flags, 'true|false');
  const afterFix = psql(DB, ['-tAc', 'SELECT count(*) FROM public.kiosk_vacation_requests']);
  assert.equal(afterFix.trim(), before.trim());

  const created = psql(DB, ['-tAc', `
    SELECT status || '|' || start_date::text || '|' || end_date::text || '|' || coalesce(note, '')
    FROM public.vacation_request_create('2222', DATE '2026-12-15', DATE '2026-12-17', 'puente')
  `]);
  assert.equal(created.trim(), 'pending_manager|2026-12-15|2026-12-17|puente');

  const requestId = psql(DB, ['-tAc', `
    SELECT id FROM public.kiosk_vacation_requests
    WHERE employee_id = '${ABRAHAM}' AND start_date = DATE '2026-12-15'
  `]).trim();

  const managerStep = psql(DB, ['-tAc', `
    SELECT status FROM public.vacation_manager_decide('1111', '${requestId}', 'approved', NULL)
  `]);
  assert.equal(managerStep.trim(), 'pending_hr');

  const hrStep = psql(DB, ['-tAc', `
    SELECT status FROM public.admin_decide_vacation('nfg-rh', '${requestId}', 'approved', NULL)
  `]);
  assert.equal(hrStep.trim(), 'approved');

  const holiday = psql(DB, ['-tAc', `
    SELECT name FROM public.admin_save_holiday('nfg-rh', NULL, DATE '2026-12-25', 'Navidad')
  `]);
  assert.equal(holiday.trim(), 'Navidad');

  const direct = psql(DB, ['-tAc', `
    SELECT status || '|' || source
    FROM public.admin_save_vacation(
      'nfg-rh', NULL, '${ABRAHAM}', DATE '2026-11-02', DATE '2026-11-03', 'excepcion'
    )
  `]);
  assert.equal(direct.trim(), 'approved|rh_directa');

  let overlap = '';
  try {
    psql(DB, ['-c', `SELECT * FROM public.vacation_request_create('2222', DATE '2026-12-16', DATE '2026-12-16', 'choca')`]);
  } catch (err) {
    overlap = String(err.stderr || err.message);
  }
  assert.match(overlap, /se empalman/);
  assert.equal(overlap.includes('ambiguous'), false);

  const listed = psql(DB, ['-tAc', `SELECT count(*) FROM public.admin_list_vacations('nfg-rh')`]);
  assert.equal(Number(listed.trim()) >= 3, true);

  const portal = psql(DB, ['-tAc', `
    SELECT manager_name || '|' || direct_reports::text
    FROM public.vacation_portal('2222')
  `]);
  assert.equal(portal.trim(), 'LEON ALBARRAN MENA|0');

  const team = psql(DB, ['-tAc', `SELECT direct_reports FROM public.vacation_portal('1111')`]);
  assert.equal(team.trim(), '1');

  assert.equal(fs.readFileSync(path.join(root, 'sql/11_funciones_id_sin_ambiguedad.sql'), 'utf8').includes('DELETE FROM'), false);
});

test('la bitácora acepta solicitudes y festivos después del SQL 13', { skip: hasLocalPostgres() ? false : 'no hay Postgres local' }, () => {
  const auditDb = 'checador_audit_test';
  psql('postgres', ['-c', `DROP DATABASE IF EXISTS ${auditDb}`]);
  psql('postgres', ['-c', `CREATE DATABASE ${auditDb}`]);
  psql(auditDb, ['-c', `
    CREATE SCHEMA IF NOT EXISTS kiosk_internal;
    CREATE TABLE public.kiosk_employees (
      id uuid PRIMARY KEY,
      name text NOT NULL,
      pin text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      manager_id uuid
    );
    INSERT INTO public.kiosk_employees (id, name, pin) VALUES
      ('${LEON}', 'LEON ALBARRAN MENA', '1111'),
      ('${ABRAHAM}', 'ABRAHAM DEL RIO', '2222');
    UPDATE public.kiosk_employees SET manager_id = '${LEON}' WHERE id = '${ABRAHAM}';
    CREATE TABLE public.kiosk_holidays (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      holiday_date date NOT NULL,
      name text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    );
    CREATE TABLE public.kiosk_vacation_requests (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      employee_id uuid NOT NULL,
      start_date date NOT NULL,
      end_date date NOT NULL,
      note text,
      status text NOT NULL,
      source text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    );
    CREATE TABLE public.kiosk_audit_log (
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
      CONSTRAINT kiosk_audit_log_table_chk
        CHECK (table_name IN ('kiosk_attendance', 'kiosk_employees'))
    );
    CREATE OR REPLACE FUNCTION kiosk_internal.kiosk_audit_hash(
      p_table text, p_record_id text, p_action text, p_old jsonb, p_new jsonb,
      p_actor_role text, p_actor_uid uuid, p_db_role text,
      p_logged_at timestamptz, p_prev_hash text
    ) RETURNS text LANGUAGE sql AS $$
      SELECT rpad(md5(coalesce(p_table, '') || coalesce(p_record_id, '') || coalesce(p_action, '')), 64, 'a');
    $$;
    CREATE OR REPLACE FUNCTION kiosk_internal.write_kiosk_audit(
      p_table text, p_record_id text, p_action text, p_old jsonb, p_new jsonb,
      p_actor_role text, p_actor_uid uuid, p_db_role text
    ) RETURNS void LANGUAGE plpgsql AS $$
    BEGIN
      IF p_table NOT IN ('kiosk_attendance', 'kiosk_employees') THEN
        RAISE EXCEPTION 'Tabla fuera de la bitácora';
      END IF;
    END $$;
    CREATE OR REPLACE FUNCTION kiosk_internal.audit_kiosk_change()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM kiosk_internal.write_kiosk_audit(
        TG_TABLE_NAME,
        CASE WHEN TG_OP = 'DELETE' THEN OLD.id::text ELSE NEW.id::text END,
        TG_OP,
        CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END,
        current_user, NULL, current_user
      );
      IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
      RETURN NEW;
    END $$;
    CREATE TRIGGER kiosk_vacation_requests_audit
      AFTER INSERT OR UPDATE OR DELETE ON public.kiosk_vacation_requests
      FOR EACH ROW EXECUTE FUNCTION kiosk_internal.audit_kiosk_change();
    CREATE OR REPLACE FUNCTION kiosk_internal.admin_code_ok(p_code text)
    RETURNS boolean LANGUAGE sql AS $$ SELECT p_code = 'nfg-rh' $$;
  `]);

  let blocked = '';
  try {
    psql(auditDb, ['-c', `
      INSERT INTO public.kiosk_vacation_requests (
        employee_id, start_date, end_date, note, status, source
      ) VALUES (
        '${ABRAHAM}', DATE '2026-12-15', DATE '2026-12-17', 'graduacion', 'pending_manager', 'solicitud'
      )
    `]);
  } catch (err) {
    blocked = String(err.stderr || err.message);
  }
  assert.match(blocked, /Tabla fuera de la bitácora/);
  const none = psql(auditDb, ['-tAc', 'SELECT count(*) FROM public.kiosk_vacation_requests']);
  assert.equal(none.trim(), '0');

  psqlFile(auditDb, path.join(__dirname, 'sql/13_bitacora_festivos_vacaciones.sql'));
  psql(auditDb, ['-c', `
    INSERT INTO public.kiosk_vacation_requests (
      employee_id, start_date, end_date, note, status, source
    ) VALUES (
      '${ABRAHAM}', DATE '2026-12-15', DATE '2026-12-17', 'graduacion', 'pending_manager', 'solicitud'
    );
    INSERT INTO public.kiosk_holidays (holiday_date, name) VALUES (DATE '2026-12-25', 'Navidad');
    UPDATE public.kiosk_vacation_requests
       SET status = 'pending_hr'
     WHERE employee_id = '${ABRAHAM}';
  `]);
  const saved = psql(auditDb, ['-tAc', 'SELECT count(*) FROM public.kiosk_vacation_requests']);
  const holidays = psql(auditDb, ['-tAc', 'SELECT count(*) FROM public.kiosk_holidays']);
  const audited = psql(auditDb, ['-tAc', `
    SELECT count(DISTINCT table_name) FROM public.kiosk_audit_log
    WHERE table_name IN ('kiosk_vacation_requests', 'kiosk_holidays')
  `]);
  assert.equal(saved.trim(), '1');
  assert.equal(holidays.trim(), '1');
  assert.equal(audited.trim(), '2');

  const check = psql(auditDb, ['-tAc', `
    SELECT (p.prosrc LIKE '%kiosk_vacation_requests%')::text
      || '|' || (p.prosrc LIKE '%kiosk_holidays%')::text
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'kiosk_internal' AND p.proname = 'write_kiosk_audit'
  `]);
  assert.equal(check.trim(), 'true|true');
});

test('el saldo LFT y los dias personales se aplican en el servidor', { skip: hasLocalPostgres() ? false : 'no hay Postgres local' }, () => {
  const db = 'checador_saldo_test';
  psql('postgres', ['-c', `DROP DATABASE IF EXISTS ${db}`]);
  psql('postgres', ['-c', `CREATE DATABASE ${db}`]);
  psql(db, ['-c', `
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        CREATE ROLE service_role NOLOGIN;
      END IF;
    END $$;
    CREATE TABLE public.kiosk_employees (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      name text NOT NULL,
      pin text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now()
    );
    INSERT INTO public.kiosk_employees (id, name, pin) VALUES
      ('${LEON}', 'LEON ALBARRAN MENA', '1111'),
      ('${ABRAHAM}', 'ABRAHAM DEL RIO', '2222');
  `]);
  psqlFile(db, path.join(__dirname, 'sql/10_festivos_y_vacaciones.sql'));
  psqlFile(db, path.join(__dirname, 'sql/14_saldo_vacaciones_y_dias_personales.sql'));

  const scale = psql(db, ['-tAc', `
    SELECT kiosk_internal.lft_vacation_days(1)
      || '|' || kiosk_internal.lft_vacation_days(2)
      || '|' || kiosk_internal.lft_vacation_days(5)
      || '|' || kiosk_internal.lft_vacation_days(6)
      || '|' || kiosk_internal.lft_vacation_days(10)
      || '|' || kiosk_internal.lft_vacation_days(11)
      || '|' || kiosk_internal.lft_vacation_days(31)
      || '|' || kiosk_internal.lft_vacation_days(0)
  `]).trim();
  assert.equal(scale, '12|14|20|22|22|24|32|0');

  function fails(sql) {
    try {
      psql(db, ['-c', sql]);
      return '';
    } catch (err) {
      return String(err.stderr || err.stdout || err.message);
    }
  }

  assert.match(
    fails(`SELECT public.vacation_request_create('2222', DATE '2026-12-15', DATE '2026-12-17', 'puente', 'vacaciones')`),
    /fecha de ingreso/
  );
  assert.match(
    fails(`SELECT public.admin_save_vacation('nfg-rh', NULL, '${ABRAHAM}', DATE '2026-12-15', DATE '2026-12-17', 'directa', 'vacaciones', true)`),
    /fecha de ingreso/
  );

  psql(db, ['-c', `SELECT public.admin_set_fecha_ingreso('nfg-rh', '${ABRAHAM}', DATE '2020-01-15')`]);
  const created = psql(db, ['-tAc', `
    SELECT status FROM public.vacation_request_create('2222', DATE '2026-12-15', DATE '2026-12-17', 'puente', 'vacaciones')
  `]).trim();
  assert.equal(created, 'pending_manager');

  assert.match(
    fails(`SELECT public.vacation_request_create('2222', DATE '2026-11-16', DATE '2026-12-14', 'de mas', 'vacaciones')`),
    /saldo no alcanza/
  );

  const personal = psql(db, ['-tAc', `
    SELECT status FROM public.vacation_request_create('2222', DATE '2026-10-01', DATE '2026-10-02', 'tramite', 'personal')
  `]).trim();
  assert.equal(personal, 'pending_manager');
  assert.match(
    fails(`SELECT public.vacation_request_create('2222', DATE '2026-10-05', DATE '2026-10-05', 'otro', 'personal')`),
    /2 días personales/
  );
  assert.match(
    fails(`SELECT public.vacation_request_create('2222', DATE '2026-12-14', DATE '2026-12-14', 'pegado', 'personal')`),
    /no puede pegarse/
  );

  const forced = psql(db, ['-tAc', `
    SELECT status FROM public.admin_save_vacation(
      'nfg-rh', NULL, '${ABRAHAM}', DATE '2026-11-16', DATE '2026-12-14', 'exceso', 'vacaciones', true
    )
  `]).trim();
  assert.equal(forced, 'approved');
  assert.match(
    fails(`SELECT public.admin_save_vacation('nfg-rh', NULL, '${ABRAHAM}', DATE '2026-10-05', DATE '2026-10-07', 'no', 'personal', true)`),
    /2 días personales/
  );

  const stillThere = psql(db, ['-tAc', `SELECT count(*) FROM public.kiosk_vacation_requests WHERE status <> 'cancelled'`]);
  assert.ok(Number(stillThere) >= 3);
});
