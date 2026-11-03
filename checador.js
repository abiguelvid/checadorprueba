/* Checador Nanofactor
   Cliente compartido del tablero, el kiosko y la admin.
   Habla con Supabase por la anon key. Si las funciones o las columnas
   de ubicación todavía no existen, vuelve al comportamiento anterior.
   El código de abajo solo aplica ANTES de correr sql/03. Después, el
   código válido es el de la tabla kiosk_settings (ver README-checador.md). */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.Checador = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  const SUPABASE_URL = 'https://pjicnaamvuluommctphb.supabase.co';
  const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBqaWNuYWFtdnVsdW9tbWN0cGhiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI0ODUwMjcsImV4cCI6MjA4ODA2MTAyN30.RevJFA0u6Ts4la2vyjgaTgtvqFWeqJTo0zrCg8wOCOY';
  const ADMIN_ACCESS_CODE_FALLBACK = 'nfg-rh';

  const state = {
    adminMode: null,
    verifyMode: null,
    registerMode: null
  };

  function resetClientState() {
    state.adminMode = null;
    state.verifyMode = null;
    state.registerMode = null;
  }

  function normalizeName(name) {
    return String(name ?? '').replace(/\s+/g, ' ').trim();
  }

  function isValidPin(pin) {
    return /^[0-9]{4}$/.test(String(pin ?? '').trim());
  }

  function padPin(pin) {
    const digits = String(pin ?? '').replace(/\D/g, '');
    if (!digits) return '';
    return digits.padStart(4, '0').slice(-4);
  }

  function generateUniquePin(existingPins, rng) {
    const random = typeof rng === 'function' ? rng : Math.random;
    const used = new Set();
    for (const pin of existingPins || []) {
      const padded = padPin(pin);
      if (padded) used.add(padded);
    }
    if (used.size >= 9000) {
      throw new Error('No quedan PIN de 4 dígitos disponibles');
    }
    for (let i = 0; i < 2000; i++) {
      const pin = String(1000 + Math.floor(random() * 9000));
      if (!used.has(pin)) return pin;
    }
    for (let n = 1000; n <= 9999; n++) {
      const pin = String(n);
      if (!used.has(pin)) return pin;
    }
    throw new Error('No quedan PIN de 4 dígitos disponibles');
  }

  function asCoord(value) {
    if (value == null || value === '') return null;
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }

  function mapsUrl(lat, lng) {
    const la = asCoord(lat);
    const ln = asCoord(lng);
    if (la == null || ln == null) return null;
    if (la < -90 || la > 90 || ln < -180 || ln > 180) return null;
    return 'https://www.google.com/maps?q=' + encodeURIComponent(la + ',' + ln);
  }

  function readCoords(row) {
    if (!row) return null;
    const lat = asCoord(row.lat != null ? row.lat : row.latitude);
    const lng = asCoord(row.lng != null ? row.lng : row.longitude);
    if (lat == null || lng == null) return null;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    const accuracy = row.accuracy == null || row.accuracy === '' ? null : Number(row.accuracy);
    return {
      lat,
      lng,
      accuracy: Number.isFinite(accuracy) ? accuracy : null
    };
  }

  function sanitizeLocation(location) {
    return readCoords(location);
  }

  function escapeAttr(value) {
    return String(value)
      .replace(/&/g, '&amp;')
      .replace(/"/g, '&quot;')
      .replace(/</g, '&lt;');
  }

  function errText(err) {
    if (!err) return '';
    return [err.code, err.status, err.message, err.details].filter(Boolean).join(' ');
  }

  function isMissingFunction(err) {
    const blob = errText(err);
    return err.status === 404
      || err.code === 'PGRST202'
      || err.code === '42883'
      || /PGRST202/.test(blob)
      || /Could not find the function/i.test(blob)
      || /function .+ does not exist/i.test(blob);
  }

  function isMissingLocationColumn(err) {
    const blob = errText(err);
    const missing = err.code === 'PGRST204'
      || err.code === '42703'
      || /PGRST204/.test(blob)
      || /42703/.test(blob)
      || /schema cache/i.test(blob)
      || /does not exist/i.test(blob);
    return missing && /\b(lat|lng|accuracy)\b/i.test(blob);
  }

  function isAdminAuthError(err) {
    const blob = errText(err);
    return err.code === '28000' || /C[oó]digo de acceso incorrecto/.test(blob);
  }

  function isPinForbidden(err) {
    const blob = errText(err);
    return err.code === '42501' && /pin/i.test(blob)
      || /permission denied for column pin/i.test(blob);
  }

  function assertId(id) {
    if (!/^[0-9a-fA-F-]{8,40}$/.test(String(id || ''))) {
      throw new Error('Identificador inválido');
    }
  }

  function authError() {
    const err = new Error('Código de acceso incorrecto');
    err.code = '28000';
    return err;
  }

  async function toError(res) {
    const text = await res.text();
    let message = text || ('Error ' + res.status);
    let code = '';
    let details = '';
    try {
      const body = JSON.parse(text);
      message = body.message || message;
      code = body.code || '';
      details = body.details || '';
      if (body.hint) details = (details + ' ' + body.hint).trim();
    } catch (_) { /* cuerpo de texto */ }
    const err = new Error(message);
    err.status = res.status;
    err.code = code;
    err.details = details;
    return err;
  }

  async function request(path, options) {
    const opts = options || {};
    const headers = {
      apikey: SUPABASE_KEY,
      Authorization: 'Bearer ' + SUPABASE_KEY,
      Accept: 'application/json'
    };
    if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
    if (opts.prefer) headers.Prefer = opts.prefer;
    const init = {
      method: opts.method || 'GET',
      headers
    };
    if (opts.body !== undefined) init.body = JSON.stringify(opts.body);
    if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
      init.signal = AbortSignal.timeout(20000);
    }
    const res = await fetch(SUPABASE_URL + '/rest/v1/' + path, init);
    if (res.status === 204) return null;
    if (!res.ok) throw await toError(res);
    const text = await res.text();
    if (!text) return null;
    return JSON.parse(text);
  }

  async function rpc(fn, args) {
    const data = await request('rpc/' + fn, { method: 'POST', body: args || {} });
    if (data == null) return [];
    return Array.isArray(data) ? data : [data];
  }

  async function insertRow(table, row) {
    const data = await request(table, {
      method: 'POST',
      body: row,
      prefer: 'return=representation'
    });
    if (Array.isArray(data)) return data[0] || null;
    return data || null;
  }

  function listDirectory() {
    return request('kiosk_employees?select=id,name&order=name.asc');
  }

  async function fetchAttendance(empId, dateFrom, dateTo) {
    assertId(empId);
    const filter = 'employee_id=eq.' + empId
      + '&timestamp=gte.' + encodeURIComponent(dateFrom)
      + '&timestamp=lte.' + encodeURIComponent(dateTo)
      + '&order=timestamp.asc';
    try {
      const rows = await request('kiosk_attendance?select=action,timestamp,lat,lng,accuracy&' + filter);
      return rows || [];
    } catch (err) {
      if (!isMissingLocationColumn(err)) throw err;
      const rows = await request('kiosk_attendance?select=action,timestamp&' + filter);
      return rows || [];
    }
  }

  async function verifyPin(pin) {
    const clean = String(pin || '').trim();
    if (!isValidPin(clean)) return null;

    if (state.verifyMode !== 'direct') {
      try {
        const rows = await rpc('verify_pin', { p_pin: clean });
        state.verifyMode = 'rpc';
        return rows[0] || null;
      } catch (err) {
        if (!isMissingFunction(err)) throw err;
        state.verifyMode = 'direct';
      }
    }

    let rows;
    try {
      rows = await request('kiosk_employees?select=id,name&pin=eq.' + clean + '&limit=1');
    } catch (err) {
      if (isPinForbidden(err)) {
        throw new Error('No se puede validar el PIN desde el navegador. Corre sql/03_seguridad_pin_y_admin.sql en Supabase y recarga.');
      }
      throw err;
    }
    const emp = rows && rows[0];
    if (!emp) return null;

    let isCheckedIn = false;
    try {
      assertId(emp.id);
      const att = await request(
        'kiosk_attendance?select=action&employee_id=eq.' + emp.id + '&order=timestamp.desc&limit=1'
      );
      isCheckedIn = !!(att && att[0] && att[0].action === 'checkin');
    } catch (_) { /* el indicador de dentro/fuera es opcional */ }

    return { id: emp.id, name: emp.name, is_checked_in: isCheckedIn };
  }

  function normalizePunch(row, fallback) {
    const src = row || {};
    const fb = fallback || {};
    let saved;
    if (typeof src.saved_location === 'boolean') saved = src.saved_location;
    else if (src.lat != null && src.lng != null) saved = true;
    else if (row) saved = false;
    else saved = !!fb.saved_location;
    return {
      employee_id: src.employee_id || src.id || fb.employee_id || null,
      employee_name: src.employee_name || src.name || fb.employee_name || '',
      action: src.action || fb.action,
      marked_at: src.marked_at || src.timestamp || new Date().toISOString(),
      saved_location: saved
    };
  }

  async function registerAttendance(input) {
    const cleanPin = String(input && input.pin || '').trim();
    const action = input && input.action;
    if (!isValidPin(cleanPin)) throw new Error('Ingresa un PIN de 4 dígitos');
    if (action !== 'checkin' && action !== 'checkout') throw new Error('Acción no válida');
    const loc = sanitizeLocation(input.location);

    if (state.registerMode !== 'direct') {
      try {
        const rows = await rpc('register_attendance', {
          p_pin: cleanPin,
          p_action: action,
          p_lat: loc ? loc.lat : null,
          p_lng: loc ? loc.lng : null,
          p_accuracy: loc ? loc.accuracy : null
        });
        state.registerMode = 'rpc';
        if (!rows[0]) throw new Error('No se pudo registrar');
        return normalizePunch(rows[0], { action, saved_location: !!loc });
      } catch (err) {
        if (!isMissingFunction(err)) throw err;
        state.registerMode = 'direct';
      }
    }

    const emp = await verifyPin(cleanPin);
    if (!emp) throw new Error('PIN no encontrado');
    const base = {
      employee_id: emp.id,
      employee_name: emp.name,
      action,
      timestamp: new Date().toISOString()
    };

    let inserted = null;
    let sentLocation = false;
    if (loc) {
      try {
        inserted = await insertRow('kiosk_attendance', {
          employee_id: base.employee_id,
          employee_name: base.employee_name,
          action: base.action,
          timestamp: base.timestamp,
          lat: loc.lat,
          lng: loc.lng,
          accuracy: loc.accuracy
        });
        sentLocation = true;
      } catch (err) {
        if (!isMissingLocationColumn(err)) throw err;
        inserted = await insertRow('kiosk_attendance', base);
      }
    } else {
      inserted = await insertRow('kiosk_attendance', base);
    }

    return normalizePunch(inserted, {
      action,
      employee_id: emp.id,
      employee_name: emp.name,
      saved_location: sentLocation
    });
  }

  function readLocation() {
    const geo = typeof navigator !== 'undefined' ? navigator.geolocation : null;
    if (!geo || typeof geo.getCurrentPosition !== 'function') {
      return Promise.resolve(null);
    }
    return new Promise(function (resolve) {
      let done = false;
      const finish = function (value) {
        if (done) return;
        done = true;
        resolve(value);
      };
      const timer = setTimeout(function () { finish(null); }, 9000);
      geo.getCurrentPosition(
        function (pos) {
          clearTimeout(timer);
          finish(sanitizeLocation(pos && pos.coords));
        },
        function () {
          clearTimeout(timer);
          finish(null);
        },
        { enableHighAccuracy: true, timeout: 8000, maximumAge: 120000 }
      );
    });
  }

  async function listEmployeesDirect() {
    try {
      return await request('kiosk_employees?select=id,name,pin,created_at&order=name.asc') || [];
    } catch (err) {
      if (isPinForbidden(err)) {
        throw new Error('La columna PIN ya no es visible y falta la función de administración. Corre sql/03_seguridad_pin_y_admin.sql.');
      }
      throw err;
    }
  }

  async function adminList(code) {
    const clean = String(code || '');
    if (!clean.trim()) throw authError();

    if (state.adminMode !== 'direct') {
      try {
        const rows = await rpc('admin_list_employees', { p_code: clean });
        state.adminMode = 'rpc';
        return rows;
      } catch (err) {
        if (!isMissingFunction(err)) throw err;
      }
    }

    if (clean !== ADMIN_ACCESS_CODE_FALLBACK) throw authError();
    const rows = await listEmployeesDirect();
    state.adminMode = 'direct';
    return rows;
  }

  async function adminAdd(code, name, pin) {
    const cleanName = normalizeName(name);
    const cleanPin = String(pin || '').trim();
    if (cleanName.length < 2) throw new Error('Escribe el nombre del empleado');
    if (!isValidPin(cleanPin)) throw new Error('El PIN debe tener 4 dígitos');

    if (state.adminMode !== 'direct') {
      try {
        const rows = await rpc('admin_add_employee', {
          p_code: String(code || ''),
          p_name: cleanName,
          p_pin: cleanPin
        });
        state.adminMode = 'rpc';
        return rows[0] || { name: cleanName, pin: cleanPin };
      } catch (err) {
        if (!isMissingFunction(err)) throw err;
      }
    }

    if (String(code || '') !== ADMIN_ACCESS_CODE_FALLBACK) throw authError();
    const existing = await listEmployeesDirect();
    const nameKey = cleanName.toLocaleLowerCase('es');
    if ((existing || []).some(function (row) {
      return normalizeName(row.name).toLocaleLowerCase('es') === nameKey;
    })) {
      throw new Error('Ya existe un empleado con ese nombre');
    }
    if ((existing || []).some(function (row) { return padPin(row.pin) === cleanPin; })) {
      throw new Error('Ese PIN ya está asignado');
    }
    try {
      const inserted = await insertRow('kiosk_employees', { name: cleanName, pin: cleanPin });
      state.adminMode = 'direct';
      return inserted || { name: cleanName, pin: cleanPin };
    } catch (err) {
      if (err.code === '42501' || /permission denied/i.test(errText(err))) {
        throw new Error('La base ya no acepta altas directas. Recarga la página; si sigue igual, corre sql/03_seguridad_pin_y_admin.sql.');
      }
      throw err;
    }
  }

  async function adminDelete(code, id) {
    assertId(id);
    if (state.adminMode !== 'direct') {
      try {
        await rpc('admin_delete_employee', { p_code: String(code || ''), p_id: id });
        state.adminMode = 'rpc';
        return true;
      } catch (err) {
        if (!isMissingFunction(err)) throw err;
      }
    }
    if (String(code || '') !== ADMIN_ACCESS_CODE_FALLBACK) throw authError();
    try {
      const data = await request('kiosk_employees?id=eq.' + id, {
        method: 'DELETE',
        prefer: 'return=representation'
      });
      const rows = Array.isArray(data) ? data : [];
      if (data && !Array.isArray(data)) return true;
      if (!rows.length && data !== null) throw new Error('Empleado no encontrado');
      state.adminMode = 'direct';
      return true;
    } catch (err) {
      if (err.code === '42501' || /permission denied/i.test(errText(err))) {
        throw new Error('La base ya no acepta bajas directas. Recarga la página; si sigue igual, corre sql/03_seguridad_pin_y_admin.sql.');
      }
      throw err;
    }
  }

  return {
    SUPABASE_URL,
    ADMIN_ACCESS_CODE_FALLBACK,
    resetClientState,
    normalizeName,
    isValidPin,
    padPin,
    generateUniquePin,
    mapsUrl,
    readCoords,
    escapeAttr,
    isMissingFunction,
    isMissingLocationColumn,
    isAdminAuthError,
    isPinForbidden,
    listDirectory,
    fetchAttendance,
    verifyPin,
    registerAttendance,
    readLocation,
    adminList,
    adminAdd,
    adminDelete
  };
});
