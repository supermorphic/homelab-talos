
printf '%s\n' 'restore_stage=artifact-selection'
selected=''
requested_bundle="${AUTOMATION_DATA_RESTORE_BUNDLE:-}"
if test -n "$requested_bundle"; then
  printf '%s\n' "$requested_bundle" |
    grep -Eq '^automation-data-[0-9]{8}T[0-9]{6}Z$' || restore_fail artifact-selection
  candidate="$BACKUP_DIR/$requested_bundle"
  validate_bundle "$candidate" || restore_fail artifact-selection
  selected="$candidate"
else
  for candidate in $(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
    -name 'automation-data-*' | LC_ALL=C sort -r); do
    if validate_bundle "$candidate"; then
      selected="$candidate"
      break
    fi
  done
fi
test -n "$selected" || restore_fail artifact-selection
selected_name="$(basename "$selected")"
cp /tmp/restore-databases-base64 /tmp/restore-expected-databases-base64
