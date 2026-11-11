const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const Checador = require('./checador.js');

const RAW_NAMES = [
  'LEON ALBARRAN MENA',
  'MONICA RABASA',
  'PAULINA CÓRDOVA WALTERSPIEL',
  'VIVIANA ABIGUEL VIDAL HERRERA',
  'DIEGO ANTONIO PONCE ELIZALDE',
  'ABRAHAM DEL RÍO  MONTERROSO',
  'RODRIGO LEO SAINT ANDRE',
  'GWYNETH VALERIA MORALES  CASTRO ',
  'ENRIQUE RODRIGUEZ JIMENEZ',
  'JORGE URIEL MENDOZA BOBADILLA',
  'RICARDO ARTEMIO GARCÍA GARCÍA',
  'ROBERTO GONZALEZ FUENTES',
  'CARLOS EDUARDO PEREZ JASSO',
  'ANA KAREN ANDRADE VELEZ',
  'ANGEL  SANCHEZ  JIMENEZ ',
  'MANUEL ABRAHAM PINKUS RODRÍGUEZ',
  'NIVARDO ADRIÁN  ZACATECO  PRAXEDIZ ',
  'FRANCISCO IVÁN GONZÁLEZ MARTÍNEZ',
  'JESÚS RODRIGO  LÓPEZ  ORDAZ'
];

function read(rel) {
  return fs.readFileSync(path.join(__dirname, rel), 'utf8');
}

function seedPairs(sql) {
  const pairs = [];
  const re = /\(\s*\d+\s*,\s*'([^']+)'\s*,\s*'(\d{4})'\s*\)/g;
  let match;
  while ((match = re.exec(sql))) pairs.push([match[1], match[2]]);
  return pairs;
}

function readmePairs(md) {
  const pairs = [];
  for (const line of md.split('\n')) {
    const match = line.match(/^\| ([^|]+?) \| (\d{4}) \|$/);
    if (match && match[1] !== 'Nombre') pairs.push([match[1], match[2]]);
  }
  return pairs;
}

function jsonResponse(status, body) {
  return {
    status,
    ok: status >= 200 && status < 300,
    async text() {
      return body == null ? '' : JSON.stringify(body);
    }
  };
}

test('los 19 nombres normalizados coinciden en SQL y README', () => {
  const expected = RAW_NAMES.map(name => Checador.normalizeName(name));
  assert.equal(expected.length, 19);
  assert.equal(new Set(expected).size, 19);
  expected.forEach(name => {
    assert.equal(name, name.normalize('NFC'));
    assert.equal(name, Checador.normalizeName(name));
    assert.doesNotMatch(name, /\s{2}/);
  });

  const fromSql = seedPairs(read('sql/02_seed_empleados.sql'));
  assert.deepEqual(fromSql.map(pair => pair[0]), expected);
  assert.equal(readmePairs(read('README-checador.md')).length, 0);

  const pins = fromSql.map(pair => pair[1]);
  assert.equal(new Set(pins).size, 19);
  assert.equal(pins.includes('5293'), false);
  pins.forEach(pin => {
    assert.match(pin, /^[1-9][0-9]{3}$/);
  });
  const published = [
    'kiosk-check-in.html',
    'admin-empleados.html',
    'external-check-in-dashboard.html',
    'checador.js',
    'README-checador.md'
  ];
  published.forEach(file => {
    const text = read(file);
    pins.forEach(pin => {
      assert.equal(text.includes(pin), false, file + ' publica un PIN del seed');
    });
  });
  assert.equal(Checador.ADMIN_ACCESS_CODE_FALLBACK, 'nfg-rh');
  assert.match(read('sql/03_seguridad_pin_y_admin.sql'), /'nfg-rh'/);
  assert.match(read('checador.js'), /ADMIN_ACCESS_CODE_FALLBACK = 'nfg-rh'/);
});

test('el PIN aleatorio no choca y conserva 4 dígitos', () => {
  const used = ['5293', 2465, '3352'];
  const seen = new Set(used.map(Checador.padPin));
  for (let i = 0; i < 50; i++) {
    const pin = Checador.generateUniquePin(used, () => (i * 17 % 1000) / 1000);
    assert.match(pin, /^[1-9][0-9]{3}$/);
    assert.equal(seen.has(pin), false);
  }
});

test('arma enlace de mapa solo con coordenadas válidas', () => {
  assert.equal(Checador.mapsUrl(19.43, -99.13), 'https://www.google.com/maps?q=19.43%2C-99.13');
  assert.equal(Checador.mapsUrl(null, -99), null);
  assert.equal(Checador.mapsUrl(91, 0), null);
  assert.deepEqual(Checador.readCoords({ lat: '19.5', lng: '-99.2', accuracy: '12.4' }), {
    lat: 19.5,
    lng: -99.2,
    accuracy: 12.4
  });
  assert.equal(Checador.readCoords({ lat: null, lng: 1 }), null);
});

test('verify_pin usa la función y no el fallback si responde vacío', async () => {
  Checador.resetClientState();
  const calls = [];
  global.fetch = async (url, options) => {
    calls.push({ url, body: options.body ? JSON.parse(options.body) : null });
    return jsonResponse(200, []);
  };
  const found = await Checador.verifyPin('2465');
  assert.equal(found, null);
  assert.equal(calls.length, 1);
  assert.match(calls[0].url, /\/rpc\/verify_pin$/);
  assert.deepEqual(calls[0].body, { p_pin: '2465' });
});

test('sin la función, el kiosko busca el PIN en la tabla y registra sin ubicación', async () => {
  Checador.resetClientState();
  const calls = [];
  global.fetch = async (url, options) => {
    calls.push({ url, method: options.method || 'GET', body: options.body ? JSON.parse(options.body) : null });
    if (url.endsWith('/rpc/verify_pin') || url.endsWith('/rpc/register_attendance')) {
      return jsonResponse(404, {
        code: 'PGRST202',
        message: 'Could not find the function public.verify_pin in the schema cache'
      });
    }
    if (url.includes('kiosk_employees?select=id,name&pin=eq.2465')) {
      return jsonResponse(200, [{ id: '11111111-1111-1111-1111-111111111111', name: 'LEON ALBARRAN MENA' }]);
    }
    if (url.includes('kiosk_attendance?select=action')) {
      return jsonResponse(200, [{ action: 'checkout' }]);
    }
    if (url.endsWith('/kiosk_attendance') && options.method === 'POST') {
      assert.equal(calls.at(-1).body.lat, undefined);
      return jsonResponse(201, [{
        employee_name: 'LEON ALBARRAN MENA',
        action: 'checkin',
        timestamp: '2026-11-03T15:00:00Z'
      }]);
    }
    return jsonResponse(500, { message: 'inesperado ' + url });
  };

  const row = await Checador.registerAttendance({ pin: '2465', action: 'checkin', location: null });
  assert.equal(row.employee_name, 'LEON ALBARRAN MENA');
  assert.equal(row.saved_location, false);
  assert.equal(row.action, 'checkin');
});

test('si faltan columnas de ubicación, reintenta el insert sin ellas', async () => {
  Checador.resetClientState();
  const bodies = [];
  global.fetch = async (url, options) => {
    const body = options.body ? JSON.parse(options.body) : null;
    if (url.endsWith('/rpc/register_attendance')) {
      return jsonResponse(404, { code: 'PGRST202', message: 'Could not find the function public.register_attendance' });
    }
    if (url.endsWith('/rpc/verify_pin')) {
      return jsonResponse(200, [{ id: '11111111-1111-1111-1111-111111111111', name: 'MONICA RABASA', is_checked_in: false }]);
    }
    if (options.method === 'POST') {
      bodies.push(body);
      if (body.lat != null) {
        return jsonResponse(400, {
          code: 'PGRST204',
          message: "Could not find the 'lat' column of 'kiosk_attendance' in the schema cache"
        });
      }
      return jsonResponse(201, []);
    }
    return jsonResponse(500, { message: url });
  };

  const row = await Checador.registerAttendance({
    pin: '3352',
    action: 'checkout',
    location: { lat: 19.4, lng: -99.1, accuracy: 20 }
  });
  assert.equal(bodies.length, 2);
  assert.equal(bodies[0].lat, 19.4);
  assert.equal(bodies[1].lat, undefined);
  assert.equal(bodies[1].employee_name, 'MONICA RABASA');
  assert.equal(row.saved_location, false);
});

test('con la función nueva manda la ubicación y no inserta directo', async () => {
  Checador.resetClientState();
  global.fetch = async (url, options) => {
    if (url.endsWith('/rpc/verify_pin')) {
      return jsonResponse(200, [{ id: '55555555-5555-5555-5555-555555555555', name: 'PAULINA CÓRDOVA WALTERSPIEL', is_checked_in: false }]);
    }
    if (url.includes('select=action,timestamp')) return jsonResponse(200, []);
    assert.match(url, /\/rpc\/register_attendance$/);
    const body = JSON.parse(options.body);
    assert.deepEqual(body, {
      p_pin: '3656',
      p_action: 'checkin',
      p_lat: 19.432,
      p_lng: -99.133,
      p_accuracy: 8
    });
    return jsonResponse(200, [{
      employee_name: 'PAULINA CÓRDOVA WALTERSPIEL',
      action: 'checkin',
      marked_at: '2026-11-03T15:04:00Z',
      saved_location: true
    }]);
  };
  const row = await Checador.registerAttendance({
    pin: '3656',
    action: 'checkin',
    location: { latitude: 19.432, longitude: -99.133, accuracy: 8 }
  });
  assert.equal(row.saved_location, true);
  assert.equal(row.employee_name, 'PAULINA CÓRDOVA WALTERSPIEL');
});

test('el tablero pide ubicación y, si no existe la columna, la omite', async () => {
  Checador.resetClientState();
  const urls = [];
  global.fetch = async (url) => {
    urls.push(url);
    if (url.includes('lat,lng,accuracy')) {
      return jsonResponse(400, { code: 'PGRST204', message: "Could not find the 'lat' column of 'kiosk_attendance' in the schema cache" });
    }
    return jsonResponse(200, [{ action: 'checkin', timestamp: '2026-11-03T15:00:00Z' }]);
  };
  const id = '22222222-2222-2222-2222-222222222222';
  const rows = await Checador.fetchAttendance(id, '2026-11-01T00:00:00.000Z', '2026-11-30T23:59:59.000Z');
  assert.equal(rows.length, 1);
  assert.equal(urls.length, 2);
  assert.equal(urls[0].includes('select=action,timestamp,lat,lng,accuracy'), true);
  assert.equal(urls[1].includes('select=action,timestamp&'), true);
  assert.equal(urls[1].includes('lat'), false);
});

test('el directorio público no pide la columna pin', async () => {
  Checador.resetClientState();
  let seen = '';
  global.fetch = async (url) => {
    seen = url;
    return jsonResponse(200, []);
  };
  await Checador.listDirectory();
  assert.match(seen, /select=id,name/);
  assert.equal(seen.includes('pin'), false);
});

test('antes de la migración el código distinto de nfg-rh no lista empleados', async () => {
  Checador.resetClientState();
  global.fetch = async () => jsonResponse(404, {
    code: 'PGRST202',
    message: 'Could not find the function public.admin_list_employees'
  });
  await assert.rejects(() => Checador.adminList('otra-cosa'), /Código de acceso incorrecto/);
});

test('antes de la migración nfg-rh lista, agrega y borra directo', async () => {
  Checador.resetClientState();
  const calls = [];
  global.fetch = async (url, options) => {
    calls.push({ url, method: options.method || 'GET', body: options.body ? JSON.parse(options.body) : null });
    if (url.includes('/rpc/')) {
      return jsonResponse(404, { code: 'PGRST202', message: 'Could not find the function public.admin_list_employees' });
    }
    if (options.method === 'POST') {
      return jsonResponse(201, [{ id: '33333333-3333-3333-3333-333333333333', name: 'NUEVA PERSONA', pin: '4444' }]);
    }
    if (options.method === 'DELETE') {
      return jsonResponse(200, [{ id: '33333333-3333-3333-3333-333333333333' }]);
    }
    if (url.includes('kiosk_attendance?select=id&')) return jsonResponse(200, []);
    return jsonResponse(200, [{ id: '33333333-3333-3333-3333-333333333333', name: 'Erick Torres', pin: '5293' }]);
  };

  const listed = await Checador.adminList('nfg-rh');
  assert.equal(listed[0].name, 'Erick Torres');
  await assert.rejects(() => Checador.adminAdd('nfg-rh', 'Erick Torres', '7777'), /Ya existe/);
  await assert.rejects(() => Checador.adminAdd('nfg-rh', 'Otra Persona', '5293'), /PIN ya está asignado/);
  const created = await Checador.adminAdd('nfg-rh', 'NUEVA  PERSONA', '4444');
  assert.equal(created.pin, '4444');
  assert.equal(calls.some(call => call.body && call.body.name === 'NUEVA PERSONA'), true);
  await Checador.adminDelete('nfg-rh', '33333333-3333-3333-3333-333333333333');
  assert.equal(calls.some(call => call.method === 'DELETE'), true);
});

test('con las funciones, la admin manda el código y no lee pin directo', async () => {
  Checador.resetClientState();
  const calls = [];
  global.fetch = async (url, options) => {
    calls.push({ url, body: JSON.parse(options.body) });
    if (url.endsWith('/rpc/admin_list_employees')) {
      if (JSON.parse(options.body).p_code !== 'codigo-real') {
        return jsonResponse(400, { code: '28000', message: 'Código de acceso incorrecto' });
      }
      return jsonResponse(200, [{ id: '33333333-3333-3333-3333-333333333333', name: 'LEON ALBARRAN MENA', pin: '2465' }]);
    }
    if (url.endsWith('/rpc/admin_add_employee')) {
      return jsonResponse(200, [{ id: '44444444-4444-4444-4444-444444444444', name: 'NUEVA PERSONA', pin: '4444' }]);
    }
    return jsonResponse(400, { code: '28000', message: 'Código de acceso incorrecto' });
  };

  await assert.rejects(() => Checador.adminList('mal'), /Código de acceso incorrecto/);
  const rows = await Checador.adminList('codigo-real');
  assert.equal(rows[0].pin, '2465');
  await Checador.adminAdd('codigo-real', 'NUEVA PERSONA', '4444');
  assert.equal(calls.every(call => call.url.includes('/rpc/')), true);
  assert.equal(calls.some(call => call.body.p_code === 'codigo-real'), true);
});

test('no repite la misma acción dentro de un minuto', async () => {
  Checador.resetClientState();
  const posts = [];
  global.fetch = async (url, options) => {
    if (url.endsWith('/rpc/verify_pin') || url.endsWith('/rpc/register_attendance')) {
      return jsonResponse(404, { code: 'PGRST202', message: 'Could not find the function public.verify_pin in the schema cache' });
    }
    if (url.includes('kiosk_employees?select=id,name&pin=eq.')) {
      return jsonResponse(200, [{ id: '11111111-1111-1111-1111-111111111111', name: 'Persona' }]);
    }
    if (url.includes('select=action,timestamp') || url.includes('select=action&')) {
      return jsonResponse(200, [{ action: 'checkin', timestamp: new Date().toISOString() }]);
    }
    if (options.method === 'POST') {
      posts.push(JSON.parse(options.body));
      return jsonResponse(201, [{ employee_name: 'Persona', action: 'checkin', timestamp: new Date().toISOString() }]);
    }
    return jsonResponse(500, { message: url });
  };

  await assert.rejects(
    () => Checador.registerAttendance({ pin: '2465', action: 'checkin', location: { lat: 19.4, lng: -99.1, accuracy: 10 } }),
    /hace un momento/
  );
  assert.equal(posts.length, 0);

  global.fetch = async (url, options) => {
    if (url.endsWith('/rpc/verify_pin') || url.endsWith('/rpc/register_attendance')) {
      return jsonResponse(404, { code: 'PGRST202', message: 'Could not find the function public.register_attendance in the schema cache' });
    }
    if (url.includes('kiosk_employees?select=id,name&pin=eq.')) {
      return jsonResponse(200, [{ id: '11111111-1111-1111-1111-111111111111', name: 'Persona' }]);
    }
    if (url.includes('select=action,timestamp') || url.includes('select=action&')) {
      return jsonResponse(200, [{ action: 'checkin', timestamp: new Date(Date.now() - 5 * 60 * 1000).toISOString() }]);
    }
    if (options.method === 'POST') {
      posts.push(JSON.parse(options.body));
      return jsonResponse(201, [{
        employee_name: 'Persona',
        action: 'checkout',
        timestamp: new Date().toISOString(),
        lat: 19.4,
        lng: -99.1,
        accuracy: 10
      }]);
    }
    return jsonResponse(500, { message: url });
  };
  const row = await Checador.registerAttendance({
    pin: '2465',
    action: 'checkout',
    location: { lat: 19.4, lng: -99.1, accuracy: 10 }
  });
  assert.equal(row.action, 'checkout');
  assert.equal(row.saved_location, true);
  assert.equal(posts.length, 1);
  assert.equal(posts[0].lat, 19.4);
});

test('quitar colaborador no borra la ficha si ya hay asistencia', async () => {
  Checador.resetClientState();
  const calls = [];
  global.fetch = async (url, options) => {
    calls.push({ url, method: options.method || 'GET' });
    if (url.includes('/rpc/')) {
      return jsonResponse(404, { code: 'PGRST202', message: 'Could not find the function public.admin_delete_employee' });
    }
    if (url.includes('kiosk_attendance?select=id&')) {
      return jsonResponse(200, [{ id: '99999999-9999-9999-9999-999999999999' }]);
    }
    if (options.method === 'DELETE') return jsonResponse(200, [{ id: '33333333-3333-3333-3333-333333333333' }]);
    return jsonResponse(200, []);
  };
  await assert.rejects(
    () => Checador.adminDelete('nfg-rh', '33333333-3333-3333-3333-333333333333'),
    /ya tiene asistencia/
  );
  assert.equal(calls.some(call => call.method === 'DELETE'), false);
});

test('el día de CDMX y el listado de registros piden la ubicación', async () => {
  const bounds = Checador.cdmxDayBounds('2026-11-03');
  assert.equal(bounds.from, '2026-11-03T06:00:00.000Z');
  assert.equal(bounds.to, '2026-11-04T05:59:59.999Z');
  assert.equal(Checador.actionLabel('checkin'), 'Entrada');
  assert.match(Checador.formatCdmx('2026-11-03T15:10:00Z'), /09:10/);

  let seen = '';
  global.fetch = async (url) => {
    seen = url;
    return jsonResponse(200, [{
      employee_name: 'Persona',
      action: 'checkin',
      timestamp: '2026-11-03T15:10:00Z',
      lat: null,
      lng: null
    }]);
  };
  const id = '22222222-2222-2222-2222-222222222222';
  const rows = await Checador.listRecords(id, '2026-11-03');
  assert.equal(rows[0].lat, null);
  assert.match(seen, /select=id,employee_id,employee_name,action,timestamp,lat,lng,accuracy/);
  assert.match(seen, new RegExp('employee_id=eq.' + id));
  assert.equal(Checador.mapsUrl(rows[0].lat, rows[0].lng), null);
});
