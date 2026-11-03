-- Checador · paso 1 de 3
-- Agrega ubicación opcional a cada registro de asistencia.
-- Se puede correr más de una vez. No borra datos.
-- Proyecto: https://pjicnaamvuluommctphb.supabase.co
-- Ejecutar en SQL Editor. No modifica otras tablas.

ALTER TABLE public.kiosk_attendance
  ADD COLUMN IF NOT EXISTS lat double precision,
  ADD COLUMN IF NOT EXISTS lng double precision,
  ADD COLUMN IF NOT EXISTS accuracy double precision;

COMMENT ON COLUMN public.kiosk_attendance.lat IS
  'Latitud WGS84 capturada por el navegador. NULL si la persona negó el permiso o la ubicación falló.';
COMMENT ON COLUMN public.kiosk_attendance.lng IS
  'Longitud WGS84. NULL si no hubo ubicación.';
COMMENT ON COLUMN public.kiosk_attendance.accuracy IS
  'Precisión reportada por el navegador, en metros. NULL si no hubo ubicación.';
