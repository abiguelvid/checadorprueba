-- Checador · paso 2 de 3
-- Alta de 19 empleados. No incluye a Erick Torres (PIN 5293, ya existe).
-- Los nombres conservan acentos y mayúsculas; solo se colapsan espacios de más.
-- Idempotente: si el nombre ya existe (aunque tenga espacios dobles o otra
-- capitalización), no se inserta otra vez y no se le cambia el PIN.
-- Si uno de estos PIN ya lo tiene otra persona, no inserta a nadie y avisa.
-- Se puede correr más de una vez.

DROP TABLE IF EXISTS pg_temp._checador_seed;
CREATE TEMP TABLE _checador_seed (
  ord int PRIMARY KEY,
  emp_name text NOT NULL,
  emp_pin text NOT NULL
);

INSERT INTO _checador_seed (ord, emp_name, emp_pin) VALUES
  (1,  'LEON ALBARRAN MENA',                  '2465'),
  (2,  'MONICA RABASA',                       '3352'),
  (3,  'PAULINA CÓRDOVA WALTERSPIEL',         '3656'),
  (4,  'VIVIANA ABIGUEL VIDAL HERRERA',       '3671'),
  (5,  'DIEGO ANTONIO PONCE ELIZALDE',        '4181'),
  (6,  'ABRAHAM DEL RÍO MONTERROSO',          '3188'),
  (7,  'RODRIGO LEO SAINT ANDRE',             '1895'),
  (8,  'GWYNETH VALERIA MORALES CASTRO',      '9663'),
  (9,  'ENRIQUE RODRIGUEZ JIMENEZ',           '5160'),
  (10, 'JORGE URIEL MENDOZA BOBADILLA',       '9678'),
  (11, 'RICARDO ARTEMIO GARCÍA GARCÍA',       '9328'),
  (12, 'ROBERTO GONZALEZ FUENTES',            '2874'),
  (13, 'CARLOS EDUARDO PEREZ JASSO',          '3921'),
  (14, 'ANA KAREN ANDRADE VELEZ',             '8418'),
  (15, 'ANGEL SANCHEZ JIMENEZ',               '4101'),
  (16, 'MANUEL ABRAHAM PINKUS RODRÍGUEZ',     '6324'),
  (17, 'NIVARDO ADRIÁN ZACATECO PRAXEDIZ',    '9209'),
  (18, 'FRANCISCO IVÁN GONZÁLEZ MARTÍNEZ',    '3935'),
  (19, 'JESÚS RODRIGO LÓPEZ ORDAZ',           '6120');

DO $$
DECLARE
  rec record;
  pin_type text;
  norm text;
  pending int := 0;
BEGIN
  IF (SELECT count(*) FROM _checador_seed) <> 19 THEN
    RAISE EXCEPTION 'El seed debe tener 19 empleados';
  END IF;
  IF (SELECT count(DISTINCT emp_pin) FROM _checador_seed) <> 19 THEN
    RAISE EXCEPTION 'Hay PIN repetidos en el seed';
  END IF;
  IF EXISTS (SELECT 1 FROM _checador_seed WHERE emp_pin = '5293') THEN
    RAISE EXCEPTION 'El seed no puede usar el PIN 5293';
  END IF;
  IF EXISTS (SELECT 1 FROM _checador_seed WHERE emp_pin !~ '^[0-9]{4}$') THEN
    RAISE EXCEPTION 'Todos los PIN del seed deben tener 4 dígitos';
  END IF;

  SELECT c.data_type INTO pin_type
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'kiosk_employees'
    AND c.column_name = 'pin';

  IF pin_type IS NULL THEN
    RAISE EXCEPTION 'No existe public.kiosk_employees.pin';
  END IF;

  FOR rec IN SELECT * FROM _checador_seed ORDER BY ord LOOP
    norm := lower(regexp_replace(trim(rec.emp_name), '\s+', ' ', 'g'));

    IF EXISTS (
      SELECT 1 FROM public.kiosk_employees e
      WHERE lower(regexp_replace(trim(e.name), '\s+', ' ', 'g')) = norm
    ) THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.kiosk_employees e
      WHERE lpad(btrim(e.pin::text), 4, '0') = rec.emp_pin
    ) THEN
      RAISE EXCEPTION
        'El PIN % previsto para % ya está usado. No se insertó a nadie. Cambia ese PIN en el script y vuelve a correrlo.',
        rec.emp_pin, rec.emp_name;
    END IF;

    pending := pending + 1;
  END LOOP;

  FOR rec IN SELECT * FROM _checador_seed ORDER BY ord LOOP
    norm := lower(regexp_replace(trim(rec.emp_name), '\s+', ' ', 'g'));

    IF EXISTS (
      SELECT 1 FROM public.kiosk_employees e
      WHERE lower(regexp_replace(trim(e.name), '\s+', ' ', 'g')) = norm
    ) THEN
      RAISE NOTICE 'Sin cambios, ya existe: %', rec.emp_name;
      CONTINUE;
    END IF;

    IF pin_type IN ('smallint', 'integer', 'bigint', 'numeric') THEN
      EXECUTE
        'INSERT INTO public.kiosk_employees (name, pin, created_at) VALUES ($1, $2::integer, now())'
        USING rec.emp_name, rec.emp_pin;
    ELSE
      EXECUTE
        'INSERT INTO public.kiosk_employees (name, pin, created_at) VALUES ($1, $2, now())'
        USING rec.emp_name, rec.emp_pin;
    END IF;

    RAISE NOTICE 'Alta: % · PIN %', rec.emp_name, rec.emp_pin;
  END LOOP;

  RAISE NOTICE 'Listo. Altas nuevas en esta corrida: %', pending;
END $$;

DROP TABLE IF EXISTS pg_temp._checador_seed;
