-- Diagnóstico de SOLO LECTURA. No inserta, no actualiza y no borra.
-- Pégalo en el SQL Editor. Sirve para confirmar por qué Storage rechazó la foto.
--
-- Si la causa es la de sql/07, la columna with_check trae
-- storage.foldername(e.name) y carpeta_mal queda vacía o distinta del id,
-- mientras carpeta_bien es el id.

SELECT id, name, public, file_size_limit, allowed_mime_types
FROM storage.buckets
WHERE id = 'attendance-photos';

SELECT policyname, cmd, roles::text AS roles, qual, with_check
FROM pg_policies
WHERE schemaname = 'storage'
  AND tablename = 'objects'
  AND policyname LIKE 'attendance_photos%';

SELECT
  with_check LIKE '%foldername(e.name)%' AS compara_el_nombre_de_la_persona,
  with_check LIKE '%foldername(objects.name)%' AS compara_la_ruta_del_archivo
FROM pg_policies
WHERE schemaname = 'storage'
  AND tablename = 'objects'
  AND policyname = 'attendance_photos_insert';

SELECT
  e.name,
  e.id::text AS id,
  (storage.foldername(e.name))[1] AS carpeta_mal,
  (storage.foldername(e.id::text || '/2026-11-18/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg'))[1] AS carpeta_bien,
  storage.extension(e.id::text || '/2026-11-18/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg') AS extension
FROM public.kiosk_employees AS e
WHERE e.name ILIKE '%VIVIANA%'
ORDER BY e.name;

SELECT
  has_table_privilege('anon', 'storage.objects', 'INSERT') AS anon_puede_insertar,
  has_table_privilege('anon', 'public.kiosk_employees', 'SELECT') AS anon_puede_leer_empleados,
  has_schema_privilege('anon', 'kiosk_internal', 'USAGE') AS anon_usa_kiosk_internal,
  has_function_privilege('anon', 'kiosk_internal.attendance_photo_registered(text)', 'EXECUTE') AS anon_ejecuta_funcion_de_firma;
