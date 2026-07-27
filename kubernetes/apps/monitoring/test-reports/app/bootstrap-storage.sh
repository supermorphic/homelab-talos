#!/bin/sh
set -eu

storage_root="${TEST_REPORTS_STORAGE_ROOT:-/srv}"
state_root="$storage_root/state"
generation="$state_root/generations/bootstrap"

mkdir -p \
  "$storage_root/reports" \
  "$storage_root/artifacts" \
  "$state_root/generations" \
  "$generation/api"

if [ ! -f "$generation/catalog.json" ]; then
  printf '%s\n' '{"schema_version":1,"generated_at":null,"runs":[]}' \
    >"$generation/catalog.json"
fi
if [ ! -f "$generation/state.json" ]; then
  printf '%s\n' \
    '{"schema_version":1,"generation":"bootstrap","seen_runs":{},"runs_total":{},"cases_total":{},"last_success":{}}' \
    >"$generation/state.json"
fi
if [ ! -f "$generation/history.jsonl" ]; then
  : >"$generation/history.jsonl"
fi
if [ ! -f "$generation/api/homepage.json" ]; then
  printf '%s\n' '{"items":[]}' >"$generation/api/homepage.json"
fi
if [ ! -f "$generation/api/metrics.prom" ]; then
  printf '%s\n' \
    '# No operator-published test runs yet.' \
    >"$generation/api/metrics.prom"
fi
if [ ! -f "$generation/index.html" ]; then
  printf '%s\n' \
    '<!doctype html><html><head><meta charset="utf-8"><title>Test Reports</title></head><body><main><h1>Test Reports</h1><p>No reports have been published yet.</p></main></body></html>' \
    >"$generation/index.html"
fi

if [ ! -e "$state_root/current" ] && [ ! -L "$state_root/current" ]; then
  ln -s generations/bootstrap "$state_root/current"
fi
