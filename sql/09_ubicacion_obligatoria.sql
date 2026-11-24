-- Checador · paso 9
-- La ubicación deja de ser opcional en checadas nuevas.
--
-- NO se ejecutó contra la base. Córralo en el SQL Editor, después del 01.
-- Se puede correr más de una vez. No borra filas, no inventa lat/lng para
-- el historial y no toca fotos, Storage ni la bitácora.
--
-- Qué hace:
--   * Un trigger BEFORE INSERT rechaza el renglón si lat o lng faltan,
--     no son números finitos o están fuera de rango. La transacción
--     se aborta: no queda checada ni fila de auditoría.
--   * En UPDATE, si el renglón YA tenía lat y lng, no deja borrarlos.
--     Las checadas viejas sin ubicación se pueden seguir actualizando
--     (por ejemplo sql/05 limpia photo_path). No se les exige ubicación
--     ni se les rellena.
--
-- Por qué no es NOT NULL ni un CHECK:
--   * SET NOT NULL recorre la tabla y falla si ya hay NULL.
--   * Un CHECK, aunque sea NOT VALID, también se exige en cada UPDATE.
--     Una checada vieja sin coordenadas no se podría tocar.
--
-- Alcance: vale para cualquier insert, no solo para este kiosko. Si la
-- app de Render (u otro cliente) sigue escribiendo sin coordenadas, ese
-- insert nuevo falla. Los registros que ya están sin ubicación se quedan.
--
-- Si más adelante se vuelve a correr sql/03, 04, 06 u 08, su
-- register_attendance puede intentar insertar con lat/lng nulos. Este
-- trigger igual rechaza ese insert. No hace falta volver a crear la función.

CREATE SCHEMA IF NOT EXISTS kiosk_internal;

REVOKE ALL ON SCHEMA kiosk_internal FROM PUBLIC;
GRANT USAGE ON SCHEMA kiosk_internal TO anon, authenticated;

CREATE OR REPLACE FUNCTION kiosk_internal.kiosk_attendance_require_location()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_ok boolean;
BEGIN
  IF TG_OP IS NULL THEN
    RAISE EXCEPTION 'La ubicación solo se valida desde el trigger'
      USING ERRCODE = '42501';
  END IF;

  v_ok := NEW.lat IS NOT NULL
    AND NEW.lng IS NOT NULL
    AND NEW.lat = NEW.lat
    AND NEW.lng = NEW.lng
    AND NEW.lat BETWEEN -90 AND 90
    AND NEW.lng BETWEEN -180 AND 180;

  IF TG_OP = 'INSERT' THEN
    IF v_ok IS NOT TRUE THEN
      RAISE EXCEPTION 'Falta la ubicación. Activa la ubicación del aparato, permite que el navegador la use y vuelve a intentar. No se registró la asistencia.'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.lat IS NOT NULL
     AND OLD.lng IS NOT NULL
     AND OLD.lat = OLD.lat
     AND OLD.lng = OLD.lng
     AND v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'No se puede quitar la ubicación de una checada. No se cambió el registro.'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION kiosk_internal.kiosk_attendance_require_location() IS
  'Rechaza checadas nuevas sin lat/lng válidos. No modifica ni rellena filas viejas sin ubicación.';

REVOKE ALL ON FUNCTION kiosk_internal.kiosk_attendance_require_location() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION kiosk_internal.kiosk_attendance_require_location() TO anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION kiosk_internal.kiosk_attendance_require_location() TO service_role';
  END IF;
END $$;

DROP TRIGGER IF EXISTS kiosk_attendance_require_location ON public.kiosk_attendance;
CREATE TRIGGER kiosk_attendance_require_location
  BEFORE INSERT OR UPDATE ON public.kiosk_attendance
  FOR EACH ROW
  EXECUTE FUNCTION kiosk_internal.kiosk_attendance_require_location();

COMMENT ON COLUMN public.kiosk_attendance.lat IS
  'Latitud WGS84. Obligatoria en checadas nuevas (sql/09). NULL solo en registros anteriores; no se rellenan.';
COMMENT ON COLUMN public.kiosk_attendance.lng IS
  'Longitud WGS84. Obligatoria en checadas nuevas (sql/09). NULL solo en registros anteriores; no se rellenan.';
COMMENT ON COLUMN public.kiosk_attendance.accuracy IS
  'Precisión reportada por el navegador, en metros. Puede ir vacía. No sustituye a lat/lng.';
