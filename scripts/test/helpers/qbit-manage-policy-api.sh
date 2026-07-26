#!/bin/sh
# Runs only inside the ephemeral E2E API helper pod. Credentials and the SID cookie remain
# inside that pod: callers receive API response bodies, never authentication material.
set -eu

base_url='http://qbittorrent.media.svc.cluster.local:8080'
cookie_file='/tmp/qbit-manage-policy.cookie'

login() {
  umask 077
  response="$(
    curl --silent --show-error --fail \
      --max-time 30 \
      --header "Referer: ${base_url}" \
      --cookie-jar "$cookie_file" \
      --data-urlencode "username=${QBT_USER}" \
      --data-urlencode "password=${QBT_PASS}" \
      "${base_url}/api/v2/auth/login"
  )"
  [ "$response" = 'Ok.' ] || {
    echo 'qBittorrent API authentication failed.' >&2
    return 1
  }
}

api_get() {
  login
  curl --silent --show-error --fail \
    --max-time 30 \
    --header "Referer: ${base_url}" \
    --cookie "$cookie_file" \
    "$base_url$1"
}

api_post() {
  path="$1"
  shift
  login
  curl --silent --show-error --fail \
    --max-time 30 \
    --header "Referer: ${base_url}" \
    --cookie "$cookie_file" \
    --request POST \
    "$@" \
    "$base_url$path"
}

[ "$#" -ge 1 ] || { echo 'API helper command required.' >&2; exit 2; }
command="$1"
shift

case "$command" in
  info)
    [ "$#" -eq 1 ] || exit 2
    api_get "/api/v2/torrents/info?hashes=$1"
    ;;
  files)
    [ "$#" -eq 1 ] || exit 2
    api_get "/api/v2/torrents/files?hash=$1"
    ;;
  categories)
    [ "$#" -eq 0 ] || exit 2
    api_get /api/v2/torrents/categories
    ;;
  tags)
    [ "$#" -eq 0 ] || exit 2
    api_get /api/v2/torrents/tags
    ;;
  add)
    [ "$#" -eq 4 ] || exit 2
    api_post /api/v2/torrents/add \
      --form-string "urls=$1" \
      --form-string "savepath=$2" \
      --form-string "category=$3" \
      --form-string "rename=$4" \
      --form-string 'root_folder=true' \
      --form-string 'autoTMM=false' \
      --form-string 'paused=false'
    ;;
  add-tags)
    [ "$#" -eq 2 ] || exit 2
    api_post /api/v2/torrents/addTags \
      --data-urlencode "hashes=$1" \
      --data-urlencode "tags=$2"
    ;;
  remove-tags)
    [ "$#" -eq 2 ] || exit 2
    api_post /api/v2/torrents/removeTags \
      --data-urlencode "hashes=$1" \
      --data-urlencode "tags=$2"
    ;;
  create-category)
    [ "$#" -eq 2 ] || exit 2
    api_post /api/v2/torrents/createCategory \
      --data-urlencode "category=$1" \
      --data-urlencode "savePath=$2"
    ;;
  remove-category)
    [ "$#" -eq 1 ] || exit 2
    api_post /api/v2/torrents/removeCategories \
      --data-urlencode "categories=$1"
    ;;
  create-tags)
    [ "$#" -eq 1 ] || exit 2
    api_post /api/v2/torrents/createTags --data-urlencode "tags=$1"
    ;;
  delete-tags)
    [ "$#" -eq 1 ] || exit 2
    api_post /api/v2/torrents/deleteTags --data-urlencode "tags=$1"
    ;;
  delete)
    [ "$#" -eq 1 ] || exit 2
    api_post /api/v2/torrents/delete \
      --data-urlencode "hashes=$1" \
      --data-urlencode 'deleteFiles=true'
    ;;
  *)
    echo "Unknown API helper command: $command" >&2
    exit 2
    ;;
esac
