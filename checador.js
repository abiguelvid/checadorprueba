/* Checador Nanofactor
   Cliente compartido del tablero, el kiosko y la admin.
   Habla con Supabase por la anon key. Si las funciones todavía no
   existen, el kiosko inserta directo, pero nunca sin lat y lng.
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
  const DUPLICATE_WINDOW_MS = 60 * 1000;
  const PHOTO_BUCKET = 'attendance-photos';
  const PHOTO_MAX_WIDTH = 640;
  const PHOTO_JPEG_QUALITY = 0.72;
  const PHOTO_MAX_BYTES = 500 * 1024;
  const SIGNED_URL_SECONDS = 60;
  /* Texto del aviso. Edítalo aquí si cambia el aviso de privacidad
     y sube AVISO_FOTO_VERSION para que el kiosco lo vuelva a mostrar. */
  const AVISO_FOTO_VERSION = '1';
  const AVISO_FOTO = 'La foto se toma solo para validar la asistencia, conforme al aviso de privacidad de Nanofactor. No se usa para reconocimiento facial.';
  const PHOTO_PATH_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/[0-9]{4}-[0-9]{2}-[0-9]{2}\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/;

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

  function isMissingNamedColumn(err, column) {
    const blob = errText(err);
    const missing = err.code === 'PGRST204'
      || err.code === '42703'
      || /PGRST204/.test(blob)
      || /42703/.test(blob)
      || /schema cache/i.test(blob)
      || /does not exist/i.test(blob);
    return missing && new RegExp('\\b' + column + '\\b', 'i').test(blob);
  }

  function isMissingPhotoColumn(err) {
    return isMissingNamedColumn(err, 'photo_path');
  }

  function isMissingPhotoHashColumn(err) {
    return isMissingNamedColumn(err, 'photo_sha256');
  }

  function photoColumnError() {
    return new Error('Falta la columna de la foto. Corre sql/04_foto_kiosk_attendance.sql en Supabase. No se registró la asistencia.');
  }

  function photoHashColumnError() {
    return new Error('Falta la columna de la huella. Corre sql/06_bitacora_auditoria.sql en Supabase. No se registró la asistencia.');
  }

  function throwIfPhotoSchema(err) {
    if (isMissingPhotoHashColumn(err)) throw photoHashColumnError();
    if (isMissingPhotoColumn(err)) throw photoColumnError();
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

  function isPhotoPath(value) {
    return PHOTO_PATH_RE.test(String(value || ''));
  }

  function isPhotoSha256(value) {
    return /^[0-9a-f]{64}$/.test(String(value || ''));
  }

  async function sha256Hex(data) {
    let buffer;
    if (data instanceof ArrayBuffer) buffer = data;
    else if (ArrayBuffer.isView(data)) {
      buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    } else if (data && typeof data.arrayBuffer === 'function') {
      buffer = await data.arrayBuffer();
    } else {
      throw new Error('No se pudo calcular la huella de la foto. No se registró la asistencia.');
    }
    if (!crypto || !crypto.subtle || typeof crypto.subtle.digest !== 'function') {
      throw new Error('Este navegador no puede calcular la huella de la foto. No se registró la asistencia.');
    }
    const digest = await crypto.subtle.digest('SHA-256', buffer);
    return Array.from(new Uint8Array(digest), function (b) {
      return b.toString(16).padStart(2, '0');
    }).join('');
  }

  function auditActionLabel(action) {
    if (action === 'INSERT') return 'Alta';
    if (action === 'UPDATE') return 'Cambio';
    if (action === 'DELETE') return 'Baja';
    if (action === 'BASELINE') return 'Registro inicial';
    return action || '—';
  }

  function auditActorLabel(row) {
    const src = row || {};
    const role = src.actor_role || src.db_role || 'desconocido';
    if (src.actor_uid) return role + ' · ' + src.actor_uid;
    if (src.db_role && src.db_role !== role) return role + ' · ' + src.db_role;
    return role;
  }

  function auditChangedKeys(oldRow, newRow) {
    const prev = oldRow && typeof oldRow === 'object' ? oldRow : {};
    const next = newRow && typeof newRow === 'object' ? newRow : {};
    const keys = {};
    Object.keys(prev).forEach(function (key) { keys[key] = true; });
    Object.keys(next).forEach(function (key) { keys[key] = true; });
    return Object.keys(keys).filter(function (key) {
      return JSON.stringify(prev[key]) !== JSON.stringify(next[key]);
    }).sort();
  }

  function newFileId() {
    const cryptoObj = typeof crypto !== 'undefined' ? crypto : null;
    if (cryptoObj && typeof cryptoObj.randomUUID === 'function') {
      return String(cryptoObj.randomUUID()).toLowerCase();
    }
    const bytes = new Uint8Array(16);
    if (cryptoObj && typeof cryptoObj.getRandomValues === 'function') cryptoObj.getRandomValues(bytes);
    else {
      for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = Array.from(bytes, function (b) { return b.toString(16).padStart(2, '0'); }).join('');
    return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
  }

  function attendancePhotoPath(employeeId, now) {
    const id = String(employeeId || '').toLowerCase();
    assertId(id);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) {
      throw new Error('Identificador inválido');
    }
    const ymd = new Intl.DateTimeFormat('en-CA', {
      timeZone: 'America/Mexico_City',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit'
    }).format(now instanceof Date ? now : new Date());
    const path = id + '/' + ymd + '/' + newFileId() + '.jpg';
    if (!isPhotoPath(path)) throw new Error('No se pudo armar la ruta de la foto. No se registró la asistencia.');
    return path;
  }

  function fitPhotoSize(width, height, maxWidth) {
    const max = Number(maxWidth) > 0 ? Number(maxWidth) : PHOTO_MAX_WIDTH;
    const w = Number(width);
    const h = Number(height);
    if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) {
      throw new Error('La cámara no entregó imagen. No se registró la asistencia.');
    }
    if (w <= max) return { width: Math.round(w), height: Math.round(h) };
    return { width: max, height: Math.max(1, Math.round(h * (max / w))) };
  }

  function locationMessage(reason) {
    if (reason === 'denied') {
      return 'El navegador bloqueó el permiso de ubicación. En la barra de direcciones, permite la ubicación para este sitio y pulsa Reintentar. No se guardó nada.';
    }
    if (reason === 'timeout') {
      return 'La ubicación tardó demasiado. Activa el GPS del aparato, acércate a una ventana o sal un momento al aire libre y pulsa Reintentar. No se guardó nada.';
    }
    if (reason === 'unsupported') {
      return 'Este navegador no puede compartir la ubicación. Ábrelo en Chrome o Safari, activa la ubicación y pulsa Reintentar. No se guardó nada.';
    }
    if (reason === 'unavailable') {
      return 'El aparato no pudo obtener la ubicación. Activa la ubicación o el GPS en los ajustes del sistema y pulsa Reintentar. No se guardó nada.';
    }
    return 'No llegó una ubicación válida. Activa la ubicación del aparato, permite que el navegador la use y pulsa Reintentar. No se guardó nada.';
  }

  function locationRequiredError(reason) {
    const err = new Error(locationMessage(reason));
    err.code = 'LOCATION_REQUIRED';
    err.reason = reason || 'invalid';
    return err;
  }

  function locationOutcome(reason, location) {
    if (reason === 'ok' && location) {
      return { ok: true, location: location, reason: 'ok', message: '' };
    }
    const why = reason && reason !== 'ok' ? reason : 'invalid';
    return { ok: false, location: null, reason: why, message: locationMessage(why) };
  }

  function cameraErrorMessage(err) {
    const name = err && (err.name || '') || '';
    const blob = String(err && err.message || '');
    if (/No se registró la asistencia/.test(blob) && (!name || name === 'Error')) return blob;
    if (name === 'NotAllowedError' || name === 'PermissionDeniedError' || /permission|denied|notallowed/i.test(blob)) {
      return 'No se pudo usar la cámara. Autoriza el permiso de la cámara en el navegador y vuelve a intentar. No se registró la asistencia.';
    }
    if (name === 'NotFoundError' || name === 'DevicesNotFoundError' || /not found|no camera|requested device/i.test(blob)) {
      return 'Este aparato no tiene una cámara que podamos usar. No se registró la asistencia.';
    }
    if (name === 'NotReadableError' || name === 'TrackStartError' || /could not start/i.test(blob)) {
      return 'La cámara está ocupada o no responde. Cierra otras aplicaciones que la usen e inténtalo de nuevo. No se registró la asistencia.';
    }
    if (name === 'SecurityError' || name === 'NotSupportedError' || /secure context|insecure|getUserMedia is not/i.test(blob)) {
      return 'La cámara solo funciona en una página segura (HTTPS). Ábrela desde el enlace del kiosco. No se registró la asistencia.';
    }
    if (name === 'TimeoutError' || /tardó demasiado/i.test(blob)) {
      return 'La cámara tardó demasiado en abrir. No se registró la asistencia.';
    }
    if (name === 'AbortError') {
      return 'Se canceló la cámara. No se registró la asistencia.';
    }
    return 'No se pudo tomar la foto. La asistencia no se registró.';
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

  function cdmxDayBounds(ymd) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(String(ymd || ''))) {
      throw new Error('Fecha inválida');
    }
    const from = new Date(ymd + 'T00:00:00.000-06:00');
    const to = new Date(ymd + 'T23:59:59.999-06:00');
    if (Number.isNaN(from.getTime()) || Number.isNaN(to.getTime())) {
      throw new Error('Fecha inválida');
    }
    return { from: from.toISOString(), to: to.toISOString() };
  }

  function formatCdmx(iso) {
    const date = new Date(iso);
    if (Number.isNaN(date.getTime())) return '—';
    return new Intl.DateTimeFormat('es-MX', {
      timeZone: 'America/Mexico_City',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23'
    }).format(date);
  }

  function actionLabel(action) {
    if (action === 'checkin') return 'Entrada';
    if (action === 'checkout') return 'Salida';
    if (action === 'lunch_out') return 'Salida a comer';
    if (action === 'lunch_in') return 'Regreso de comer';
    return action || '—';
  }

  function needsPhoto(action) {
    return action === 'checkin' || action === 'checkout';
  }

  function isLunchAction(action) {
    return action === 'lunch_out' || action === 'lunch_in';
  }

  function isAttendanceAction(action) {
    return needsPhoto(action) || isLunchAction(action);
  }

  function presenceFromAction(action) {
    if (action === 'checkin' || action === 'lunch_in') return 'in';
    if (action === 'lunch_out') return 'lunch';
    return 'out';
  }

  function formatDuration(ms) {
    if (ms == null || !Number.isFinite(ms)) return null;
    const diffMin = Math.round(ms / 60000);
    if (diffMin < 0) return null;
    return Math.floor(diffMin / 60) + 'h ' + (diffMin % 60) + 'm';
  }

  function summarizeDay(punches) {
    const list = (punches || []).map(function (p) {
      const t = typeof p.t === 'number' ? p.t : new Date(p.timestamp).getTime();
      return { action: p.action, t: t };
    }).filter(function (p) { return Number.isFinite(p.t); })
      .sort(function (a, b) { return a.t - b.t; });
    let checkin = null;
    let checkout = null;
    let lunchMs = 0;
    let open = null;
    let firstOut = null;
    let lastIn = null;
    let meals = 0;
    list.forEach(function (p) {
      if (p.action === 'checkin' && !checkin) checkin = p;
      if (p.action === 'checkout') checkout = p;
      if (p.action === 'lunch_out') {
        open = p;
        if (!firstOut) firstOut = p;
      } else if (p.action === 'lunch_in' && open) {
        if (p.t > open.t) lunchMs += p.t - open.t;
        lastIn = p;
        meals += 1;
        open = null;
      } else if (p.action === 'checkout' && open) {
        if (p.t > open.t) lunchMs += p.t - open.t;
        meals += 1;
        open = null;
      }
    });
    let siteMs = null;
    if (checkin && checkout && checkout.t >= checkin.t) {
      siteMs = Math.max(0, checkout.t - checkin.t - lunchMs);
    }
    return {
      lunchMs: lunchMs,
      siteMs: siteMs,
      meals: meals,
      firstOut: firstOut,
      lastIn: lastIn,
      openLunch: !!open,
      lunchLabel: formatDuration(lunchMs) || '0h 0m',
      siteLabel: siteMs == null ? null : formatDuration(siteMs)
    };
  }

  function todayCdmx() {
    return new Intl.DateTimeFormat('en-CA', {
      timeZone: 'America/Mexico_City',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit'
    }).format(new Date());
  }

  async function listRecords(employeeId, ymd) {
    const bounds = cdmxDayBounds(ymd);
    let filter = '&timestamp=gte.' + encodeURIComponent(bounds.from)
      + '&timestamp=lte.' + encodeURIComponent(bounds.to)
      + '&order=timestamp.desc&limit=500';
    if (employeeId) {
      assertId(employeeId);
      filter += '&employee_id=eq.' + employeeId;
    }
    const full = 'kiosk_attendance?select=id,employee_id,employee_name,action,timestamp,lat,lng,accuracy,photo_path,photo_sha256' + filter;
    const noHash = 'kiosk_attendance?select=id,employee_id,employee_name,action,timestamp,lat,lng,accuracy,photo_path' + filter;
    const noPhoto = 'kiosk_attendance?select=id,employee_id,employee_name,action,timestamp,lat,lng,accuracy' + filter;
    const plain = 'kiosk_attendance?select=id,employee_id,employee_name,action,timestamp' + filter;
    try {
      return await request(full) || [];
    } catch (err) {
      if (isMissingPhotoHashColumn(err)) {
        try {
          return await request(noHash) || [];
        } catch (err2) {
          return await listRecordsFallback(err2, noPhoto, plain);
        }
      }
      return await listRecordsFallback(err, noPhoto, plain);
    }
  }

  async function listRecordsFallback(err, noPhoto, plain) {
    if (isMissingPhotoColumn(err)) {
      try {
        return await request(noPhoto) || [];
      } catch (err2) {
        if (!isMissingLocationColumn(err2)) throw err2;
        return await request(plain) || [];
      }
    }
    if (!isMissingLocationColumn(err)) throw err;
    return await request(plain) || [];
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
        const found = rows[0] || null;
        if (!found) return null;
        let presence = found.is_checked_in ? 'in' : 'out';
        try {
          const last = await latestPunch(found.id);
          presence = presenceFromAction(last && last.action);
        } catch (_) { /* el indicador es opcional */ }
        return {
          id: found.id,
          name: found.name,
          is_checked_in: presence === 'in',
          presence: presence
        };
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
    let presence = 'out';
    try {
      const last = await latestPunch(emp.id);
      presence = presenceFromAction(last && last.action);
      isCheckedIn = presence === 'in';
    } catch (_) { /* el indicador de dentro/fuera es opcional */ }

    return { id: emp.id, name: emp.name, is_checked_in: isCheckedIn, presence: presence };
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

  function duplicateMessage(action) {
    if (action === 'checkin') return 'Esta entrada ya se registró hace un momento. Espera un minuto para no duplicarla.';
    if (action === 'lunch_out') return 'Esta salida a comer ya se registró hace un momento. Espera un minuto para no duplicarla.';
    if (action === 'lunch_in') return 'Este regreso de comer ya se registró hace un momento. Espera un minuto para no duplicarlo.';
    return 'Esta salida ya se registró hace un momento. Espera un minuto para no duplicarla.';
  }

  async function latestPunch(employeeId) {
    assertId(employeeId);
    const rows = await request(
      'kiosk_attendance?select=action,timestamp&employee_id=eq.' + employeeId + '&order=timestamp.desc&limit=1'
    );
    return (rows && rows[0]) || null;
  }

  async function assertSequence(employeeId, action) {
    if (action !== 'lunch_out' && action !== 'lunch_in') return;
    let last;
    try {
      last = await latestPunch(employeeId);
    } catch (_) {
      throw new Error('No pude revisar la entrada abierta. No se registró la comida.');
    }
    const lastAction = last && last.action;
    if (action === 'lunch_out') {
      if (lastAction !== 'checkin' && lastAction !== 'lunch_in') {
        throw new Error('No hay una entrada abierta. Marca Entrada antes de salir a comer.');
      }
      return;
    }
    if (lastAction !== 'lunch_out' || !last.timestamp) {
      throw new Error('No hay una salida a comer de hoy. Marca Salida a comer antes del regreso.');
    }
    const bounds = cdmxDayBounds(todayCdmx());
    const t = new Date(last.timestamp).getTime();
    const from = new Date(bounds.from).getTime();
    const to = new Date(bounds.to).getTime();
    if (!(t >= from && t <= to)) {
      throw new Error('No hay una salida a comer de hoy. Marca Salida a comer antes del regreso.');
    }
  }

  async function assertFresh(employeeId, action) {
    assertId(employeeId);
    let rows;
    try {
      rows = await request(
        'kiosk_attendance?select=action,timestamp&employee_id=eq.' + employeeId + '&order=timestamp.desc&limit=1'
      );
    } catch (_) {
      return;
    }
    const last = rows && rows[0];
    if (!last || last.action !== action || !last.timestamp) return;
    const age = Date.now() - new Date(last.timestamp).getTime();
    if (Number.isFinite(age) && age >= 0 && age < DUPLICATE_WINDOW_MS) {
      throw new Error(duplicateMessage(action));
    }
  }

  async function registerAttendance(input) {
    const cleanPin = String(input && input.pin || '').trim();
    const action = input && input.action;
    const photoRequired = needsPhoto(action);
    const photoPath = String(input && input.photoPath || '');
    const photoSha256 = String(input && input.photoSha256 || '').toLowerCase();
    if (!isValidPin(cleanPin)) throw new Error('Ingresa un PIN de 4 dígitos');
    if (!isAttendanceAction(action)) throw new Error('Acción no válida');
    if (photoRequired) {
      if (!isPhotoPath(photoPath)) throw new Error('Falta la foto. No se registró la asistencia.');
      if (!isPhotoSha256(photoSha256)) throw new Error('Falta la huella de la foto. No se registró la asistencia.');
    }
    const loc = sanitizeLocation(input.location);
    if (!loc) throw locationRequiredError('invalid');
    const emp = await verifyPin(cleanPin);
    if (!emp) throw new Error('PIN no encontrado');
    if (photoRequired && photoPath.split('/')[0] !== String(emp.id || '').toLowerCase()) {
      throw new Error('La foto no corresponde al empleado. No se registró la asistencia.');
    }
    await assertFresh(emp.id, action);
    await assertSequence(emp.id, action);

    if (state.registerMode !== 'direct') {
      try {
        const rows = await rpc('register_attendance', {
          p_pin: cleanPin,
          p_action: action,
          p_lat: loc.lat,
          p_lng: loc.lng,
          p_accuracy: loc.accuracy,
          p_photo_path: photoRequired ? photoPath : null,
          p_photo_sha256: photoRequired ? photoSha256 : null
        });
        state.registerMode = 'rpc';
        if (!rows[0]) throw new Error('No se pudo registrar');
        return normalizePunch(rows[0], { action, saved_location: !!loc });
      } catch (err) {
        throwIfPhotoSchema(err);
        if (isLunchAction(action) && /Acci[oó]n no v[aá]lida/.test(String(err && err.message || ''))) {
          throw new Error('La comida todavía no está habilitada en la base. Corre sql/08_comida_kiosk_attendance.sql. No se registró.');
        }
        if (!isMissingFunction(err)) throw err;
        state.registerMode = 'direct';
      }
    }

    const base = {
      employee_id: emp.id,
      employee_name: emp.name,
      action: action,
      timestamp: new Date().toISOString()
    };
    if (photoRequired) {
      base.photo_path = photoPath;
      base.photo_sha256 = photoSha256;
    }

    let inserted = null;
    try {
      inserted = await insertRow('kiosk_attendance', Object.assign({
        employee_id: base.employee_id,
        employee_name: base.employee_name,
        action: base.action,
        timestamp: base.timestamp,
        lat: loc.lat,
        lng: loc.lng,
        accuracy: loc.accuracy
      }, photoRequired ? { photo_path: photoPath, photo_sha256: photoSha256 } : {}));
    } catch (err) {
      throwIfPhotoSchema(err);
      if (isMissingLocationColumn(err)) {
        throw new Error('Faltan las columnas de ubicación. No se registró la asistencia.');
      }
      throw err;
    }

    return normalizePunch(inserted, {
      action,
      employee_id: emp.id,
      employee_name: emp.name,
      saved_location: true
    });
  }

  function geolocationReason(err) {
    const code = err && err.code;
    if (code === 1) return 'denied';
    if (code === 3) return 'timeout';
    if (code === 2) return 'unavailable';
    return 'unavailable';
  }

  function askPosition(geo, options) {
    const timeoutMs = options.timeout;
    const watchdogMs = timeoutMs >= 1000 ? timeoutMs + 1500 : timeoutMs + 40;
    return new Promise(function (resolve) {
      let done = false;
      const finish = function (reason, location) {
        if (done) return;
        done = true;
        resolve({ reason: reason, location: location || null });
      };
      const timer = setTimeout(function () { finish('timeout', null); }, watchdogMs);
      try {
        geo.getCurrentPosition(
          function (pos) {
            clearTimeout(timer);
            const loc = sanitizeLocation(pos && pos.coords);
            finish(loc ? 'ok' : 'invalid', loc);
          },
          function (err) {
            clearTimeout(timer);
            finish(geolocationReason(err), null);
          },
          {
            enableHighAccuracy: options.enableHighAccuracy,
            timeout: timeoutMs,
            maximumAge: options.maximumAge
          }
        );
      } catch (_) {
        clearTimeout(timer);
        finish('unsupported', null);
      }
    });
  }

  /* Pide un punto válido. Si la ubicación precisa tarda o no está
     disponible, reintenta una vez con la ubicación aproximada.
     El permiso denegado no se reintenta: el navegador no vuelve a preguntar. */
  async function readLocation(options) {
    const scope = typeof globalThis !== 'undefined' ? globalThis : null;
    const nav = scope && scope.navigator;
    const geo = nav && nav.geolocation;
    if (!geo || typeof geo.getCurrentPosition !== 'function') {
      return locationOutcome('unsupported');
    }
    const opts = options || {};
    const highTimeout = Number(opts.highTimeoutMs) > 0 ? Number(opts.highTimeoutMs) : 8000;
    const lowTimeout = Number(opts.lowTimeoutMs) > 0 ? Number(opts.lowTimeoutMs) : 7000;
    const first = await askPosition(geo, {
      enableHighAccuracy: true,
      timeout: highTimeout,
      maximumAge: 60000
    });
    if (first.reason === 'ok') return locationOutcome('ok', first.location);
    if (opts.attempts === 1 || first.reason === 'denied' || first.reason === 'unsupported') {
      return locationOutcome(first.reason);
    }
    const second = await askPosition(geo, {
      enableHighAccuracy: false,
      timeout: lowTimeout,
      maximumAge: 0
    });
    if (second.reason === 'ok') return locationOutcome('ok', second.location);
    return locationOutcome(second.reason);
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

  async function employeeHasHistory(id) {
    assertId(id);
    try {
      const rows = await request('kiosk_attendance?select=id&employee_id=eq.' + id + '&limit=1');
      return !!(rows && rows.length);
    } catch (err) {
      const blocked = new Error('No quité a esta persona porque no pude confirmar si tiene asistencia. No se borró nada.');
      blocked.cause = err;
      throw blocked;
    }
  }

  async function adminDelete(code, id) {
    assertId(id);
    if (await employeeHasHistory(id)) {
      throw new Error('No se quitó: esta persona ya tiene asistencia. Borrar la ficha podría eliminar ese historial y no se cambia el esquema. La ficha se queda.');
    }
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

  async function storageRequest(path, options) {
    const opts = options || {};
    const headers = {
      apikey: SUPABASE_KEY,
      Authorization: 'Bearer ' + SUPABASE_KEY,
      Accept: 'application/json'
    };
    const extra = opts.headers || {};
    Object.keys(extra).forEach(function (key) { headers[key] = extra[key]; });
    const init = { method: opts.method || 'GET', headers };
    if (opts.body !== undefined) init.body = opts.body;
    if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
      init.signal = AbortSignal.timeout(20000);
    }
    const res = await fetch(SUPABASE_URL + '/storage/v1/' + path, init);
    if (!res.ok) throw await toError(res);
    const text = await res.text();
    if (!text) return null;
    try { return JSON.parse(text); } catch (_) { return null; }
  }

  function storageHint(err) {
    if (!err) return '';
    const status = err.status ? String(err.status) : '';
    const code = err.code ? String(err.code) : '';
    const message = String(err.message || '').replace(/\s+/g, ' ').trim().slice(0, 180);
    const bits = [status, code, message].filter(Boolean);
    return bits.length ? ' Detalle: ' + bits.join(' · ') + '.' : '';
  }

  function uploadErrorMessage(err) {
    const blob = errText(err);
    if (err && (err.status === 404 || /bucket/i.test(blob) && /not found/i.test(blob))) {
      return 'No existe el bucket privado attendance-photos. Corre sql/04_foto_kiosk_attendance.sql en Supabase.' + storageHint(err) + ' No se registró la asistencia.';
    }
    if (err && (err.status === 401 || err.status === 403 || /row-level security|unauthorized|permission/i.test(blob))) {
      return 'La base no aceptó la foto. Revisa las políticas del bucket en sql/04_foto_kiosk_attendance.sql.' + storageHint(err) + ' No se registró la asistencia.';
    }
    if (err && (err.status === 413 || /too large|payload|exceeded/i.test(blob))) {
      return 'La foto pesa demasiado.' + storageHint(err) + ' No se registró la asistencia.';
    }
    return 'No se pudo guardar la foto.' + storageHint(err) + ' No se registró la asistencia.';
  }

  function signedUrlErrorMessage(err) {
    const blob = errText(err);
    if (err && (err.status === 404 || /not found|Object not found/i.test(blob))) {
      return 'No se encontró la foto. Si el SQL todavía no se corre, o si ya se borró, no se puede abrir.';
    }
    if (err && (err.status === 401 || err.status === 403 || /row-level security|unauthorized|permission/i.test(blob))) {
      return 'No hay permiso para ver la foto. Revisa la política de lectura del bucket attendance-photos.';
    }
    return 'No se pudo abrir la foto.';
  }

  async function uploadAttendancePhoto(photoPath, blob) {
    if (!isPhotoPath(photoPath)) {
      throw new Error('La ruta de la foto no es válida. No se registró la asistencia.');
    }
    if (!blob || typeof blob.size !== 'number' || blob.size <= 0) {
      throw new Error('No se pudo preparar la foto. No se registró la asistencia.');
    }
    if (blob.size > PHOTO_MAX_BYTES) {
      throw new Error('La foto pesa demasiado. No se registró la asistencia.');
    }
    if (blob.type && blob.type !== 'image/jpeg') {
      throw new Error('La foto tiene que ser JPEG. No se registró la asistencia.');
    }
    const encoded = String(photoPath).split('/').map(encodeURIComponent).join('/');
    try {
      await storageRequest('object/' + PHOTO_BUCKET + '/' + encoded, {
        method: 'POST',
        headers: {
          'Content-Type': 'image/jpeg',
          'cache-control': 'max-age=60',
          'x-upsert': 'false'
        },
        body: blob
      });
    } catch (err) {
      throw new Error(uploadErrorMessage(err));
    }
    return photoPath;
  }

  function absoluteSignedUrl(signed) {
    const raw = String(signed || '');
    const absolute = /^https?:\/\//i.test(raw)
      ? raw
      : SUPABASE_URL + '/storage/v1' + (raw.startsWith('/') ? raw : '/' + raw);
    let parsed;
    try { parsed = new URL(absolute); } catch (_) { parsed = null; }
    const origin = new URL(SUPABASE_URL).origin;
    if (!parsed || parsed.protocol !== 'https:' || parsed.origin !== origin || !parsed.pathname.includes('/storage/v1/object/sign/')) {
      throw new Error('No se pudo abrir la foto.');
    }
    return parsed.toString();
  }

  async function signedPhotoUrl(photoPath) {
    if (!isPhotoPath(photoPath)) throw new Error('No hay foto para esta checada.');
    const encoded = String(photoPath).split('/').map(encodeURIComponent).join('/');
    let data;
    try {
      data = await storageRequest('object/sign/' + PHOTO_BUCKET + '/' + encoded, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ expiresIn: SIGNED_URL_SECONDS })
      });
    } catch (err) {
      throw new Error(signedUrlErrorMessage(err));
    }
    const signed = data && (data.signedURL || data.signedUrl);
    if (!signed) throw new Error('No se pudo abrir la foto.');
    return absoluteSignedUrl(signed);
  }

  function defaultCreateCanvas(width, height) {
    if (typeof document === 'undefined' || typeof document.createElement !== 'function') {
      throw new Error('No se pudo preparar la foto. No se registró la asistencia.');
    }
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    return canvas;
  }

  function canvasToJpeg(canvas, quality) {
    return new Promise(function (resolve, reject) {
      if (!canvas || typeof canvas.toBlob !== 'function') {
        reject(new Error('No se pudo preparar la foto. No se registró la asistencia.'));
        return;
      }
      canvas.toBlob(function (blob) {
        if (!blob) reject(new Error('No se pudo preparar la foto. No se registró la asistencia.'));
        else resolve(blob);
      }, 'image/jpeg', quality);
    });
  }

  function auditSchemaError() {
    return new Error('Falta la bitácora. Corre sql/06_bitacora_auditoria.sql en Supabase.');
  }

  async function adminAuditHistory(code, tableName, recordId) {
    if (tableName !== 'kiosk_attendance' && tableName !== 'kiosk_employees') {
      throw new Error('Tabla no válida');
    }
    if (!/^[0-9A-Za-z-]{1,80}$/.test(String(recordId || ''))) {
      throw new Error('Identificador inválido');
    }
    try {
      return await rpc('admin_list_kiosk_audit', {
        p_code: String(code || ''),
        p_table: tableName,
        p_record_id: String(recordId)
      }) || [];
    } catch (err) {
      if (isMissingFunction(err)) throw auditSchemaError();
      throw err;
    }
  }

  async function adminVerifyAudit(code) {
    try {
      const rows = await rpc('admin_verify_kiosk_audit', { p_code: String(code || '') });
      return rows[0] || null;
    } catch (err) {
      if (isMissingFunction(err)) throw auditSchemaError();
      throw err;
    }
  }

  async function photoMatchesStoredHash(photoPath, expected) {
    if (!isPhotoPath(photoPath) || !isPhotoSha256(expected)) {
      return { checked: false, ok: false, detail: 'sin huella' };
    }
    const url = await signedPhotoUrl(photoPath);
    const res = await fetch(url);
    if (!res.ok) return { checked: true, ok: false, detail: 'no se pudo leer la foto' };
    const got = await sha256Hex(await res.arrayBuffer());
    const ok = got === expected;
    return { checked: true, ok, detail: ok ? 'coincide' : 'la foto no coincide con la huella guardada' };
  }

  async function compressPhotoFromVideo(video, deps) {
    const source = video || {};
    const size = fitPhotoSize(source.videoWidth, source.videoHeight, PHOTO_MAX_WIDTH);
    const maker = deps && deps.createCanvas ? deps.createCanvas : defaultCreateCanvas;
    const canvas = maker(size.width, size.height);
    const ctx = canvas.getContext('2d');
    if (!ctx || typeof ctx.drawImage !== 'function') {
      throw new Error('No se pudo preparar la foto. No se registró la asistencia.');
    }
    ctx.drawImage(source, 0, 0, size.width, size.height);
    let blob = await canvasToJpeg(canvas, PHOTO_JPEG_QUALITY);
    if (blob.size > PHOTO_MAX_BYTES) blob = await canvasToJpeg(canvas, 0.5);
    if (!blob || blob.size <= 0 || blob.size > PHOTO_MAX_BYTES || (blob.type && blob.type !== 'image/jpeg')) {
      throw new Error('La foto pesa demasiado. No se registró la asistencia.');
    }
    return blob;
  }

  return {
    SUPABASE_URL,
    ADMIN_ACCESS_CODE_FALLBACK,
    DUPLICATE_WINDOW_MS,
    PHOTO_BUCKET,
    PHOTO_MAX_WIDTH,
    PHOTO_JPEG_QUALITY,
    PHOTO_MAX_BYTES,
    SIGNED_URL_SECONDS,
    AVISO_FOTO_VERSION,
    AVISO_FOTO,
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
    isMissingPhotoColumn,
    isMissingPhotoHashColumn,
    isPhotoPath,
    isPhotoSha256,
    sha256Hex,
    auditActionLabel,
    auditActorLabel,
    auditChangedKeys,
    attendancePhotoPath,
    fitPhotoSize,
    cameraErrorMessage,
    compressPhotoFromVideo,
    uploadAttendancePhoto,
    signedPhotoUrl,
    isAdminAuthError,
    isPinForbidden,
    listDirectory,
    cdmxDayBounds,
    formatCdmx,
    actionLabel,
    needsPhoto,
    isLunchAction,
    presenceFromAction,
    formatDuration,
    summarizeDay,
    todayCdmx,
    listRecords,
    fetchAttendance,
    verifyPin,
    registerAttendance,
    readLocation,
    adminList,
    adminAdd,
    adminDelete,
    adminAuditHistory,
    adminVerifyAudit,
    photoMatchesStoredHash
  };
});
