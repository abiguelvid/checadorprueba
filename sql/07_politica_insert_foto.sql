-- Checador · paso 7
-- Arregla la política de subida de fotos.
--
-- NO se ejecutó contra la base. Córralo en el SQL Editor después del 04 y del 06.
-- Se puede correr más de una vez. No borra fotos ni checadas.
-- No hace ALTER, COMMENT ni OWNER sobre storage.objects ni storage.buckets.
--
-- Causa: en el EXISTS de attendance_photos_insert, "name" a secas lo resolvió
-- Postgres como kiosk_employees.name (el nombre de la persona), no como la
-- ruta del archivo. La política comparaba el id con una carpeta sacada de
-- "VIVIANA ABIGUEL VIDAL HERRERA", nunca coincidía, y Storage respondía
-- "new row violates row-level security policy".
--
-- El arreglo califica la columna: storage.objects.name.

DROP POLICY IF EXISTS attendance_photos_insert ON storage.objects;

CREATE POLICY attendance_photos_insert
ON storage.objects
FOR INSERT
TO anon, authenticated
WITH CHECK (
  bucket_id = 'attendance-photos'
  AND storage.extension(name) = 'jpg'
  AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
  AND EXISTS (
    SELECT 1
    FROM public.kiosk_employees AS e
    WHERE e.id::text = (storage.foldername(storage.objects.name))[1]
  )
);
