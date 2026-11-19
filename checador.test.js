const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const Checador = require('./checador.js');

const EMP_A = '11111111-1111-1111-1111-111111111111';
const EMP_B = '55555555-5555-5555-5555-555555555555';
const PHOTO_FILE = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jpg';

function photoFor(id) {
  return id + '/2026-11-03/' + PHOTO_FILE;
}

const PHOTO_SHA = 'ab'.repeat(32);

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

  const row = await Checador.registerAttendance({ pin: '2465', action: 'checkin', location: null, photoPath: photoFor(EMP_A), photoSha256: PHOTO_SHA });
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
    location: { lat: 19.4, lng: -99.1, accuracy: 20 },
    photoPath: photoFor(EMP_A), photoSha256: PHOTO_SHA
  });
  assert.equal(bodies.length, 2);
  assert.equal(bodies[0].lat, 19.4);
  assert.equal(bodies[0].photo_path, photoFor(EMP_A));
  assert.equal(bodies[1].lat, undefined);
  assert.equal(bodies[1].photo_path, photoFor(EMP_A));
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
      p_accuracy: 8,
      p_photo_path: photoFor(EMP_B),
      p_photo_sha256: PHOTO_SHA
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
    location: { latitude: 19.432, longitude: -99.133, accuracy: 8 },
    photoPath: photoFor(EMP_B), photoSha256: PHOTO_SHA
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
    () => Checador.registerAttendance({ pin: '2465', action: 'checkin', location: { lat: 19.4, lng: -99.1, accuracy: 10 }, photoPath: photoFor(EMP_A), photoSha256: PHOTO_SHA }),
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
    location: { lat: 19.4, lng: -99.1, accuracy: 10 },
    photoPath: photoFor(EMP_A), photoSha256: PHOTO_SHA
  });
  assert.equal(row.action, 'checkout');
  assert.equal(row.saved_location, true);
  assert.equal(posts.length, 1);
  assert.equal(posts[0].lat, 19.4);
  assert.equal(posts[0].photo_path, photoFor(EMP_A));
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
  assert.match(seen, /select=id,employee_id,employee_name,action,timestamp,lat,lng,accuracy,photo_path,photo_sha256/);
  assert.match(seen, new RegExp('employee_id=eq.' + id));
  assert.equal(Checador.mapsUrl(rows[0].lat, rows[0].lng), null);
});

test('sin foto no llama a la base', async () => {
  Checador.resetClientState();
  let calls = 0;
  global.fetch = async () => {
    calls += 1;
    return jsonResponse(500, { message: 'no debería llamarse' });
  };
  await assert.rejects(
    () => Checador.registerAttendance({ pin: '2465', action: 'checkin', location: null }),
    /Falta la foto/
  );
  await assert.rejects(
    () => Checador.registerAttendance({ pin: '2465', action: 'checkin', photoPath: 'no-es-ruta' }),
    /Falta la foto/
  );
  assert.equal(calls, 0);
});

test('la foto que no es del empleado no se inserta', async () => {
  Checador.resetClientState();
  const posts = [];
  global.fetch = async (url, options) => {
    if (url.endsWith('/rpc/verify_pin') || url.endsWith('/rpc/register_attendance')) {
      return jsonResponse(404, { code: 'PGRST202', message: 'Could not find the function public.verify_pin' });
    }
    if (url.includes('kiosk_employees?select=id,name&pin=eq.')) {
      return jsonResponse(200, [{ id: EMP_A, name: 'Persona' }]);
    }
    if (options && options.method === 'POST') {
      posts.push(JSON.parse(options.body));
      return jsonResponse(201, []);
    }
    return jsonResponse(200, []);
  };
  await assert.rejects(
    () => Checador.registerAttendance({
      pin: '2465',
      action: 'checkin',
      photoPath: photoFor(EMP_B), photoSha256: PHOTO_SHA
    }),
    /no corresponde/
  );
  assert.equal(posts.length, 0);
});

test('si falta la columna photo_path no reintenta sin foto', async () => {
  Checador.resetClientState();
  const bodies = [];
  global.fetch = async (url, options) => {
    if (url.endsWith('/rpc/verify_pin')) {
      return jsonResponse(200, [{ id: EMP_A, name: 'Persona', is_checked_in: false }]);
    }
    if (url.endsWith('/rpc/register_attendance')) {
      return jsonResponse(404, { code: 'PGRST202', message: 'Could not find the function public.register_attendance' });
    }
    if (url.includes('select=action,timestamp') || url.includes('select=action&')) return jsonResponse(200, []);
    if (options && options.method === 'POST') {
      bodies.push(JSON.parse(options.body));
      return jsonResponse(400, {
        code: 'PGRST204',
        message: "Could not find the 'photo_path' column of 'kiosk_attendance' in the schema cache"
      });
    }
    return jsonResponse(500, { message: url });
  };
  await assert.rejects(
    () => Checador.registerAttendance({
      pin: '2465',
      action: 'checkout',
      location: null,
      photoPath: photoFor(EMP_A), photoSha256: PHOTO_SHA
    }),
    /sql\/04_foto_kiosk_attendance\.sql/
  );
  assert.equal(bodies.length, 1);
  assert.equal(bodies[0].photo_path, photoFor(EMP_A));
});

test('comprime a 640 px y la ruta usa el día de CDMX', async () => {
  const size = Checador.fitPhotoSize(1920, 1080, Checador.PHOTO_MAX_WIDTH);
  assert.deepEqual(size, { width: 640, height: 360 });
  assert.deepEqual(Checador.fitPhotoSize(400, 300), { width: 400, height: 300 });
  assert.throws(() => Checador.fitPhotoSize(0, 10), /no entregó imagen/);

  const path = Checador.attendancePhotoPath(EMP_A, new Date('2026-11-03T15:00:00Z'));
  assert.match(path, new RegExp('^' + EMP_A + '/2026-11-03/[0-9a-f-]{36}\\.jpg$'));
  assert.equal(Checador.isPhotoPath(path), true);

  const calls = [];
  const blob = await Checador.compressPhotoFromVideo(
    { videoWidth: 1920, videoHeight: 1080 },
    {
      createCanvas(width, height) {
        calls.push({ width, height });
        const blobs = [
          { size: Checador.PHOTO_MAX_BYTES + 1, type: 'image/jpeg' },
          { size: 1200, type: 'image/jpeg' }
        ];
        return {
          getContext() { return { drawImage() {} }; },
          toBlob(cb, type, quality) {
            calls.push({ type, quality });
            cb(blobs.shift());
          }
        };
      }
    }
  );
  assert.equal(blob.size, 1200);
  assert.equal(calls[0].width, 640);
  assert.equal(calls[1].quality, Checador.PHOTO_JPEG_QUALITY);
  assert.equal(calls[2].quality, 0.5);
});

test('los errores de cámara quedan en español y no suenan a registro hecho', () => {
  const denied = new Error('Permission denied');
  denied.name = 'NotAllowedError';
  assert.match(Checador.cameraErrorMessage(denied), /permiso de la cámara/);
  assert.match(Checador.cameraErrorMessage(denied), /No se registró la asistencia/);
  const missing = new Error('Requested device not found');
  missing.name = 'NotFoundError';
  assert.match(Checador.cameraErrorMessage(missing), /no tiene una cámara/);
  const insecure = new Error('insecure');
  insecure.name = 'SecurityError';
  assert.match(Checador.cameraErrorMessage(insecure), /HTTPS/);
  assert.match(Checador.AVISO_FOTO, /validar la asistencia/);
  assert.match(Checador.AVISO_FOTO, /aviso de privacidad/);
  assert.match(Checador.AVISO_FOTO, /No se usa para reconocimiento facial/);
});

test('sube el JPEG al bucket privado y firma la URL por 60 segundos', async () => {
  Checador.resetClientState();
  const calls = [];
  global.fetch = async (url, options) => {
    calls.push({ url, method: options.method, body: options.body, headers: options.headers });
    if (url.includes('/object/sign/')) {
      return jsonResponse(200, { signedURL: '/object/sign/attendance-photos/' + photoFor(EMP_A) + '?token=corto' });
    }
    return jsonResponse(200, { Key: 'attendance-photos/' + photoFor(EMP_A) });
  };
  const blob = { size: 800, type: 'image/jpeg' };
  await Checador.uploadAttendancePhoto(photoFor(EMP_A), blob);
  const signed = await Checador.signedPhotoUrl(photoFor(EMP_A));
  assert.equal(calls[0].method, 'POST');
  assert.match(calls[0].url, /\/storage\/v1\/object\/attendance-photos\//);
  assert.equal(calls[0].headers['Content-Type'], 'image/jpeg');
  assert.equal(calls[0].headers['x-upsert'], 'false');
  assert.equal(calls[0].body, blob);
  assert.equal(JSON.parse(calls[1].body).expiresIn, 60);
  assert.equal(signed, Checador.SUPABASE_URL + '/storage/v1/object/sign/attendance-photos/' + photoFor(EMP_A) + '?token=corto');
  await assert.rejects(() => Checador.uploadAttendancePhoto(photoFor(EMP_A), { size: 10, type: 'image/png' }), /JPEG/);
  await assert.rejects(() => Checador.signedPhotoUrl('mal'), /No hay foto/);
});

test('el error de Storage se muestra con su código', async () => {
  Checador.resetClientState();
  global.fetch = async () => jsonResponse(403, {
    statusCode: '403',
    code: '42501',
    message: 'new row violates row-level security policy'
  });
  await assert.rejects(
    () => Checador.uploadAttendancePhoto(photoFor(EMP_A), { size: 20, type: 'image/jpeg' }),
    /403 · 42501 · new row violates row-level security policy/
  );
});

test('el kiosco toma la foto antes de registrar y la admin la abre firmada', () => {
  const kiosk = read('kiosk-check-in.html');
  const mealAt = kiosk.indexOf('async function punchMeal');
  const hashAt = kiosk.indexOf('sha256Hex');
  const uploadAt = kiosk.indexOf('uploadAttendancePhoto');
  const registerAt = kiosk.lastIndexOf('registerAttendance');
  assert.equal(mealAt > 0 && mealAt < hashAt && hashAt < uploadAt && uploadAt < registerAt, true);
  assert.equal(kiosk.slice(mealAt, hashAt).includes('sha256Hex'), false);
  assert.match(kiosk, /facingMode:\s*\{\s*ideal:\s*'user'/);
  assert.match(kiosk, /playsinline/);
  assert.match(kiosk, /Checador\.AVISO_FOTO/);
  assert.match(kiosk, /Sin aceptar el aviso no se toma la foto/);
  const admin = read('admin-empleados.html');
  assert.match(admin, /Ver foto/);
  assert.match(admin, /signedPhotoUrl/);
  assert.match(admin, /dura un minuto/);
  assert.match(admin, /Verificar integridad/);
  assert.match(admin, /Historial/);
  assert.match(admin, /adminVerifyAudit/);
  assert.match(admin, /adminAuditHistory/);
});

test('el SQL de la foto deja el bucket privado y la retención apagada', () => {
  const foto = read('sql/04_foto_kiosk_attendance.sql');
  const retencion = read('sql/05_retencion_fotos_asistencia.sql');
  const paso3 = read('sql/03_seguridad_pin_y_admin.sql');
  assert.match(foto, /attendance-photos/);
  assert.match(foto, /false,\s*\n\s*512000/);
  assert.match(foto, /photo_path/);
  assert.match(foto, /attendance_photos_insert/);
  assert.match(foto, /storage\.object\.sign/);
  assert.match(foto, /p_photo_path/);
  assert.equal(/^\s*select\s+cron\.schedule/im.test(foto), false);
  assert.equal(/delete\s+from\s+storage\.objects/i.test(foto), false);
  assert.equal(/eyJ[A-Za-z0-9_-]{20,}/.test(foto), false);
  assert.match(retencion, /attendance_photos_older_than/);
  assert.match(retencion, /clear_old_attendance_photo_paths/);
  assert.match(retencion, /NO ACTIVADA|NO borra fotos/);
  assert.equal(/^\s*select\s+cron\.schedule/im.test(retencion), false);
  assert.equal(/delete\s+from\s+storage\.objects/i.test(retencion), false);
  assert.match(paso3, /p_photo_path text/);
  assert.match(paso3, /p_photo_sha256 text/);
  assert.match(paso3, /Falta la foto/);
  assert.equal(ownsStorageTable(foto), false);
  assert.equal(ownsStorageTable(retencion), false);
  assert.equal(ownsStorageTable(read('sql/06_bitacora_auditoria.sql')), false);
  assert.equal(ownsStorageTable(read('sql/07_politica_insert_foto.sql')), false);
  assert.match(stripSqlComments(foto), /storage\.foldername\(storage\.objects\.name\)/);
  assert.doesNotMatch(stripSqlComments(foto), /storage\.foldername\(name\)/);
  assert.match(stripSqlComments(read('sql/07_politica_insert_foto.sql')), /storage\.foldername\(storage\.objects\.name\)/);
  const diagnostico = read('sql/diagnostico_foto_solo_lectura.sql');
  assert.match(diagnostico, /foldername\(e\.name\)/);
  assert.equal(/^\s*(insert|update|delete|alter|drop|create)\b/im.test(stripSqlComments(diagnostico)), false);
});

function stripSqlComments(sql) {
  return sql.replace(/\/\*[\s\S]*?\*\//g, '').replace(/--.*$/gm, '');
}

function ownsStorageTable(sql) {
  const code = stripSqlComments(sql);
  return /\b(alter\s+table|comment\s+on|owner\s+to)\b[\s\S]{0,240}?\bstorage\.(objects|buckets)\b/i.test(code)
    || /\bstorage\.(objects|buckets)\b[\s\S]{0,240}?\b(alter\s+table|comment\s+on|owner\s+to)\b/i.test(code);
}

test('la huella de la foto es SHA-256 y sin ella no se llama a la base', async () => {
  const digest = await Checador.sha256Hex(new TextEncoder().encode('abc'));
  assert.equal(digest, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  assert.equal(Checador.isPhotoSha256(digest), true);
  assert.deepEqual(Checador.auditChangedKeys({ pin: '1111', name: 'A' }, { pin: '2222', name: 'A' }), ['pin']);
  assert.equal(Checador.auditActionLabel('UPDATE'), 'Cambio');
  assert.equal(Checador.auditActorLabel({ actor_role: 'anon', db_role: 'anon' }), 'anon');

  Checador.resetClientState();
  let calls = 0;
  global.fetch = async () => {
    calls += 1;
    return jsonResponse(500, { message: 'no' });
  };
  await assert.rejects(
    () => Checador.registerAttendance({
      pin: '2465',
      action: 'checkin',
      photoPath: photoFor(EMP_A)
    }),
    /huella de la foto/
  );
  assert.equal(calls, 0);
});

test('la comida no pide foto y respeta la secuencia del día', async () => {
  const day = [
    { action: 'checkin', t: 0 },
    { action: 'lunch_out', t: 4 * 60 * 60 * 1000 },
    { action: 'lunch_in', t: 5 * 60 * 60 * 1000 },
    { action: 'checkout', t: 9 * 60 * 60 * 1000 }
  ];
  const summary = Checador.summarizeDay(day);
  assert.equal(summary.lunchMs, 60 * 60 * 1000);
  assert.equal(summary.siteMs, 8 * 60 * 60 * 1000);
  assert.equal(summary.siteLabel, '8h 0m');
  assert.equal(Checador.actionLabel('lunch_out'), 'Salida a comer');
  assert.equal(Checador.presenceFromAction('lunch_out'), 'lunch');
  assert.equal(Checador.presenceFromAction('lunch_in'), 'in');
  assert.equal(Checador.needsPhoto('lunch_out'), false);
  assert.equal(Checador.needsPhoto('checkin'), true);

  Checador.resetClientState();
  const posts = [];
  global.fetch = async (url, options) => {
    if (url.endsWith('/rpc/verify_pin') || url.endsWith('/rpc/register_attendance')) {
      return jsonResponse(404, { code: 'PGRST202', message: 'Could not find the function public.register_attendance' });
    }
    if (url.includes('kiosk_employees?select=id,name&pin=eq.')) {
      return jsonResponse(200, [{ id: EMP_A, name: 'PERSONA' }]);
    }
    if (url.includes('select=action,timestamp')) {
      return jsonResponse(200, [{ action: 'checkin', timestamp: new Date().toISOString() }]);
    }
    if (options && options.method === 'POST') {
      posts.push(JSON.parse(options.body));
      return jsonResponse(201, [{ employee_name: 'PERSONA', action: 'lunch_out', timestamp: new Date().toISOString(), lat: 19.4, lng: -99.1, accuracy: 8 }]);
    }
    return jsonResponse(200, []);
  };
  const row = await Checador.registerAttendance({ pin: '2465', action: 'lunch_out', location: { lat: 19.4, lng: -99.1, accuracy: 8 } });
  assert.equal(row.action, 'lunch_out');
  assert.equal(row.saved_location, true);
  assert.equal(posts[0].photo_path, undefined);
  assert.equal(posts[0].action, 'lunch_out');

  global.fetch = async (url) => {
    if (url.endsWith('/rpc/verify_pin') || url.endsWith('/rpc/register_attendance')) {
      return jsonResponse(404, { code: 'PGRST202', message: 'Could not find the function public.verify_pin' });
    }
    if (url.includes('kiosk_employees?select=id,name&pin=eq.')) {
      return jsonResponse(200, [{ id: EMP_A, name: 'PERSONA' }]);
    }
    if (url.includes('select=action,timestamp')) {
      return jsonResponse(200, [{ action: 'checkout', timestamp: new Date().toISOString() }]);
    }
    return jsonResponse(500, { message: url });
  };
  await assert.rejects(
    () => Checador.registerAttendance({ pin: '2465', action: 'lunch_out', location: null }),
    /entrada abierta/
  );
  await assert.rejects(
    () => Checador.registerAttendance({ pin: '2465', action: 'lunch_in', location: null }),
    /salida a comer de hoy/
  );

  const sql = read('sql/08_comida_kiosk_attendance.sql');
  assert.match(sql, /lunch_out/);
  assert.match(sql, /lunch_in/);
  assert.match(sql, /NOT VALID/);
  assert.doesNotMatch(sql, /storage\.objects/);
  assert.match(read('kiosk-check-in.html'), /Salida a comer/);
  assert.match(read('kiosk-check-in.html'), /Regreso de comer/);
  assert.equal(read('kiosk-check-in.html').includes('sin foto'), false);
  assert.match(read('admin-empleados.html'), /recAction/);
  assert.match(read('external-check-in-dashboard.html'), /Minutos de comida/);
});

test('la bitácora es append-only, encadena SHA-256 y no se activa sola', () => {
  const sql = read('sql/06_bitacora_auditoria.sql');
  assert.match(sql, /kiosk_audit_log/);
  assert.match(sql, /0babb132451e906d8a2aa08a94a3f40c8e9887ec79983653ade2050cf9dc7e6a/);
  assert.match(sql, /extensions\.digest/);
  assert.match(sql, /sha256/);
  assert.match(sql, /photo_sha256/);
  assert.match(sql, /BASELINE/);
  assert.match(sql, /reject_kiosk_audit_change/);
  assert.match(sql, /BEFORE UPDATE OR DELETE/);
  assert.match(sql, /BEFORE TRUNCATE/);
  assert.match(sql, /pg_trigger_depth\(\) < 1/);
  assert.match(sql, /admin_verify_kiosk_audit/);
  assert.match(sql, /admin_list_kiosk_audit/);
  assert.match(sql, /ENABLE ROW LEVEL SECURITY/);
  assert.equal(/^\s*(delete|update)\s+from\s+public\.kiosk_audit_log/im.test(sql), false);
  assert.equal(/^\s*select\s+cron\.schedule/im.test(sql), false);
  assert.match(sql, /p_photo_sha256/);
});
