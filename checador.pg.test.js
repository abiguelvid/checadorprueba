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
