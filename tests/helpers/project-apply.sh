#!/usr/bin/env bash

set -eu
set -o pipefail

case "$0" in
  */*) helper_directory=${0%/*} ;;
  *) helper_directory=. ;;
esac
root=$(cd "$helper_directory/../.." && pwd -P)
project=$root/scripts/st-project.sh
shell=${BASH:-bash}

bind_plan=false
apply=false
case "${1:-}" in
  init|adopt) bind_plan=true ;;
  repository)
    case "${2:-}" in add|remove) bind_plan=true ;; esac
    ;;
esac
for argument in "$@"; do
  [ "$argument" != --apply ] || apply=true
done

if [ "$bind_plan" != true ] || [ "$apply" != true ]; then
  exec "$shell" "$project" "$@"
fi

preview_arguments=()
for argument in "$@"; do
  [ "$argument" != --apply ] || continue
  preview_arguments[${#preview_arguments[@]}]=$argument
done

set +e
preview_output=$("$shell" "$project" "${preview_arguments[@]}" 2>&1)
preview_status=$?
set -e
if [ "$preview_status" -ne 0 ]; then
  printf '%s\n' "$preview_output"
  exit "$preview_status"
fi

fingerprint=''
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    'PLAN_FINGERPRINT: '*)
      [ -z "$fingerprint" ] || {
        printf '%s\n' 'test helper received more than one plan fingerprint.' >&2
        exit 1
      }
      fingerprint=${line#'PLAN_FINGERPRINT: '}
      ;;
  esac
done <<EOF
$preview_output
EOF
[ -n "$fingerprint" ] || {
  printf '%s\n' 'test helper did not receive a plan fingerprint.' >&2
  exit 1
}

exec "$shell" "$project" "${preview_arguments[@]}" \
  --plan-fingerprint "$fingerprint" --apply
