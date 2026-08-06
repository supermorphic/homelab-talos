#!/bin/sh
set -eu

metrics_dir="${PLEX_DDNS_METRICS_DIR:-/metrics}"
metrics_file="$metrics_dir/metrics.prom"
temporary_file="$metrics_dir/metrics.prom.tmp.$$"
last_success_unixtime=0
umask 077

cleanup() {
  rm -f -- "$temporary_file"
}
trap cleanup EXIT INT TERM

is_ipv4() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      count++
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i + 0 > 255 || $i != sprintf("%d", $i + 0)) {
          exit 1
        }
      }
    }
    END { if (count != 1) exit 1 }
  '
}

publish_metrics() {
  check_success="$1"
  addresses_match="$2"
  {
    printf '# HELP plex_ddns_check_success Whether both DDNS comparison endpoints returned one valid IPv4 address.\n'
    printf '# TYPE plex_ddns_check_success gauge\n'
    printf 'plex_ddns_check_success %s\n' "$check_success"
    printf '# HELP plex_ddns_addresses_match Whether the public DNS A record matches the Internet-observed address.\n'
    printf '# TYPE plex_ddns_addresses_match gauge\n'
    printf 'plex_ddns_addresses_match %s\n' "$addresses_match"
    printf '# HELP plex_ddns_last_success_unixtime Unix timestamp of the last valid two-endpoint comparison.\n'
    printf '# TYPE plex_ddns_last_success_unixtime gauge\n'
    printf 'plex_ddns_last_success_unixtime %s\n' "$last_success_unixtime"
  } >"$temporary_file"
  mv -f -- "$temporary_file" "$metrics_file"
}

while :; do
  check_success=0
  addresses_match=0
  wan_address=''
  dns_output=''
  dns_address=''

  if wan_address="$(wget -qO- -T 10 https://api.ipify.org 2>/dev/null)" &&
    dns_output="$(nslookup plex.lab.supermorphic.com 1.1.1.1 2>/dev/null)"; then
    dns_address="$(printf '%s\n' "$dns_output" | awk '
      $1 == "Name:" { answer = 1; next }
      answer && $1 == "Address:" { print $2 }
    ')"
    if is_ipv4 "$wan_address" && is_ipv4 "$dns_address"; then
      check_success=1
      last_success_unixtime="$(date +%s)"
      if [ "$wan_address" = "$dns_address" ]; then
        addresses_match=1
      fi
    fi
  fi

  publish_metrics "$check_success" "$addresses_match"
  if [ "$check_success" -ne 1 ]; then
    printf 'error\n'
  elif [ "$addresses_match" -eq 1 ]; then
    printf 'success\n'
  else
    printf 'mismatch\n'
  fi
  sleep 300
done
