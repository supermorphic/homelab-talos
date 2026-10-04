#!/bin/sh
# qbit_manage can exit zero after catching a failed run. Keep that failure visible
# to Kubernetes without collecting its application log in the orchestrator.
set -eu
python3 qbit_manage.py --run
log_file=/config/logs/qbit_manage.log
if [ ! -f "$log_file" ]; then
  echo "qbit_manage did not create its expected log file" >&2
  exit 1
fi
if grep -Eq 'Exiting scheduled Run\.|Error executing qBittorrent commands:' "$log_file"; then
  echo "qbit_manage reported a failed one-shot run" >&2
  exit 1
fi
