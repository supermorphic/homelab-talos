INSERT INTO platform_operations.logical_backup_status (
  singleton,
  completed_at,
  filename,
  checksum
)
VALUES (
  true,
  :'completed_at'::timestamp with time zone,
  :'filename'::text,
  :'checksum'::character(64)
)
ON CONFLICT (singleton)
DO UPDATE SET
  completed_at = EXCLUDED.completed_at,
  filename = EXCLUDED.filename,
  checksum = EXCLUDED.checksum;
