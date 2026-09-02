\set ON_ERROR_STOP on

SELECT platform_operations.publish_backup(:'bundle', :'checksum', :'database_set_hash');
