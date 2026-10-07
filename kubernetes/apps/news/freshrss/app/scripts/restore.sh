#!/bin/sh
# Run only against new isolated targets with application and polling stopped.
set -eu
if [ "${1:-}" = --help ]; then
    echo 'Usage: sh restore.sh /backups/news/set-<id>'
    echo 'Requires empty isolated DATA_PATH and freshrss-owned PostgreSQL database via PGHOST/PGUSER/PGPASSWORD.'
    echo 'Mount the backup read-only and supply matching NEWS_APP_IMAGE, NEWS_DATABASE_IMAGE and /opt/news configuration.'
    echo 'Pre-extraction v1 sets require their matching historical configuration with extraction inputs absent.'
    echo 'v2 sets require matching mounted extraction release and extension bytes.'
    echo 'Keep application and polling stopped. Discard partial targets after failure; never retry over existing state.'
    exit 0
fi
umask 077
set_dir=${1:?complete backup directory required}
: "${DATA_PATH:?empty target required}" "${NEWS_APP_IMAGE:?}" "${NEWS_DATABASE_IMAGE:?}"
export PGCONNECT_TIMEOUT=5
export PGOPTIONS='-c statement_timeout=300000'
phase=validation
report_failure() {
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "News restore failed during $phase; discard any incomplete isolated target" >&2
    fi
}
trap report_failure EXIT
case "$set_dir" in */set-[0-9]*-*) ;; *) exit 1;; esac
timeout -s TERM -k 10 180 sh /opt/news/validate-backup.sh "$set_dir" >/dev/null 2>&1
[ "$(sed -n 's/^app_image=//p' "$set_dir/manifest")" = "$NEWS_APP_IMAGE" ]
[ "$(sed -n 's/^database_image=//p' "$set_dir/manifest")" = "$NEWS_DATABASE_IMAGE" ]
config_hash=$(cat /opt/news/* /opt/news-httpd.conf | sha256sum)
[ "$(sed -n 's/^config_sha256=//p' "$set_dir/manifest")" = "${config_hash%% *}" ]
format=$(sed -n 's/^format=//p' "$set_dir/manifest")
case "$format" in
    news-paired-v1) [ ! -e /opt/news-extraction/release.json ] ;;
    news-paired-v2)
        [ "$(sed -n 's/^extraction_release_id=//p' "$set_dir/manifest")" = "$(sh /opt/news/extraction-inputs.sh id)" ]
        [ "$(sed -n 's/^extraction_inputs_sha256=//p' "$set_dir/manifest")" = "$(sh /opt/news/extraction-inputs.sh hash)" ] ;;
    *) exit 1 ;;
esac
[ -d "$DATA_PATH" ] && [ "$DATA_PATH" != / ]
[ "$(readlink -f "$DATA_PATH")" = "$DATA_PATH" ]
[ -z "$(find "$DATA_PATH" -mindepth 1 -maxdepth 1 -print -quit)" ]
identity=$(psql -X -At --set=ON_ERROR_STOP=1 --command="SELECT current_user = 'freshrss' AND current_database() = 'freshrss' AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole FROM pg_roles WHERE rolname = current_user" 2>/dev/null)
[ "$identity" = t ]
objects=$(psql -X -At --set=ON_ERROR_STOP=1 --command="SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema'" 2>/dev/null)
[ "$objects" = 0 ]
# This marker prevents a partially restored target from becoming a running app.
: > "$DATA_PATH/.news-restore-incomplete"
phase=database
timeout -s TERM -k 10 300 pg_restore --dbname=freshrss --single-transaction \
    --exit-on-error --no-owner --no-privileges "$set_dir/database.dump" >/dev/null 2>&1
phase=filesystem
timeout -s TERM -k 10 180 tar -xmzof "$set_dir/data.tar.gz" --no-same-permissions \
    -C "$DATA_PATH" >/dev/null 2>&1
rm "$DATA_PATH/.news-restore-incomplete"
echo 'News paired restore complete in isolated targets; service remains stopped'
