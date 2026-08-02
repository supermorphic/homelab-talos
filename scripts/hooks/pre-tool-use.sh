#!/usr/bin/env bash
set -euo pipefail

command="$(yq -p=json -r '.tool_input.command // ""')"
command="${command#mise exec -- }"
control_boundary='([[:space:]]|[;&|]|$)'
checkout_or_restore='^git[[:space:]]+(checkout|restore)[[:space:]]+\.[[:space:]]*(#[[:space:]].*)?$|^git[[:space:]]+(checkout|restore)[[:space:]]+\.[[:space:]]*[;&|].*$'
unleased_force_push='(--force([[:space:]]|[;&|]|$)|[[:space:]]-f([[:space:]]|[;&|]|$))'

deny() {
  echo 'Denied irreversible git command.' >&2
  exit 2
}

if [[ "$command" =~ ^git[[:space:]]+reset[[:space:]]+--hard${control_boundary} ]]; then
  deny
fi

if [[ "$command" =~ $checkout_or_restore ]]; then
  deny
fi

if [[ "$command" =~ ^git[[:space:]]+clean([[:space:]]|$) ]]; then
  read -r -a command_parts <<<"$command"
  force=false
  expands_untracked=false
  dry_run=false

  for option in "${command_parts[@]:2}"; do
    stop_parsing=false
    case "$option" in
      *';'*) option="${option%%;*}"; stop_parsing=true ;;
      *'&&'*) option="${option%%&&*}"; stop_parsing=true ;;
      *'||'*) option="${option%%||*}"; stop_parsing=true ;;
      *'|'*) option="${option%%|*}"; stop_parsing=true ;;
    esac
    [[ "$option" == '--' ]] && break

    case "$option" in
      --force)
        force=true
        ;;
      --dir)
        expands_untracked=true
        ;;
      --dry-run)
        dry_run=true
        ;;
      -*)
        [[ "$option" == --* ]] && continue
        flags="${option#-}"
        [[ "$flags" == *f* ]] && force=true
        [[ "$flags" == *d* || "$flags" == *x* ]] && expands_untracked=true
        [[ "$flags" == *n* ]] && dry_run=true
        ;;
    esac

    [[ "$stop_parsing" == true ]] && break
  done

  if [[ "$force" == true && "$expands_untracked" == true && "$dry_run" == false ]]; then
    deny
  fi
fi

if [[ "$command" =~ ^git[[:space:]]+push[[:space:]]+ ]]; then
  force_with_lease=false
  if [[ "$command" =~ --force-with-lease([[:space:]=]|$) ]]; then
    force_with_lease=true
  fi
  if [[ "$command" =~ $unleased_force_push ]]; then
    deny
  fi
  [[ "$force_with_lease" == true ]] && exit 0
fi
