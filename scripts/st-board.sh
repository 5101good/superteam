#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
SNAPSHOT="$SCRIPT_DIR/st-project-snapshot.sh"
TICKETS="$SCRIPT_DIR/st-tickets.sh"
FRONTMATTER="$SCRIPT_DIR/lib/frontmatter.sh"

usage() {
  cat >&2 <<'EOF'
Usage: st-board.sh [--project <directory>] [--repository <id>]

Prints a read-only view derived from Current Contracts, ticket frontmatter,
Result evidence, and the named Project Snapshot.
EOF
  exit 2
}

project=.
repository_filter=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) project=${2:-}; shift 2 ;;
    --repository) repository_filter=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

task=$(bash "$SNAPSHOT" task "$project") || exit 1
if [ -n "$repository_filter" ]; then
  printf '%s\n' "$repository_filter" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9._-]*$' || {
    printf '%s\n' 'ERROR: invalid Repository ID.' >&2
    exit 2
  }
  bash "$SNAPSHOT" repositories "$project" | grep -qxF -- "$repository_filter" || {
    printf '%s\n' "ERROR: unknown Repository ID: $repository_filter" >&2
    exit 1
  }
fi

[ -d "$task" ] || {
  printf '%s\n' '(no features found)'
  exit 0
}

data=$(mktemp "${TMPDIR:-/tmp}/superteam-board.XXXXXX") || exit 1
trap 'rm -f -- "$data"' EXIT HUP INT TERM

for feature in "$task"/*; do
  [ -d "$feature" ] || continue
  [ -f "$feature/prd.md" ] || [ -f "$feature/spec.md" ] || [ -d "$feature/tickets" ] || continue
  if [ -n "$repository_filter" ]; then
    bash "$TICKETS" repositories "$feature" 2>/dev/null | grep -qxF -- "$repository_filter" || continue
  fi
  if ! status=$(bash "$TICKETS" feature-status "$feature" 2>/dev/null); then
    feature_name=$(basename "$feature")
    printf 'INVALID\t%s\t-\t-\t-\t-\n' "$feature_name" >> "$data"
    continue
  fi
  state=${status%% *}
  counts=${status#* }
  repositories=$(bash "$TICKETS" repositories "$feature" 2>/dev/null | paste -sd, -)
  claimed=''
  blocked=''
  if [ -d "$feature/tickets" ]; then
    while IFS= read -r ticket; do
      [ -n "$ticket" ] || continue
      ticket_status=$(bash "$FRONTMATTER" get "$ticket" status 2>/dev/null || true)
      case "$ticket_status" in
        claimed)
          owner=$(bash "$FRONTMATTER" get "$ticket" claimed_by 2>/dev/null || true)
          claimed_entry=$(basename "$ticket" .md):${owner:-unknown}
          if [ -n "$claimed" ]; then claimed=$claimed,$claimed_entry; else claimed=$claimed_entry; fi
          ;;
        blocked)
          blocked_entry=$(basename "$ticket" .md)
          if [ -n "$blocked" ]; then blocked=$blocked,$blocked_entry; else blocked=$blocked_entry; fi
          ;;
      esac
    done < <(find "$feature/tickets" -maxdepth 1 -type f -name '*.md' -print | LC_ALL=C sort)
  fi
  feature_name=$(basename "$feature")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$feature_name" \
    "$counts" "${repositories:--}" "${claimed:--}" "${blocked:--}" >> "$data"
done

[ -s "$data" ] || {
  printf '%s\n' '(no features found)'
  exit 0
}

printf '%-9s %-34s %-45s %s\n' STATE FEATURE TICKETS REPOSITORIES
printf '%s\n' '--------------------------------------------------------------------------------------------------------------'
LC_ALL=C sort -t $'\t' -k1,1 -k2,2 "$data" |
  while IFS=$'\t' read -r state feature counts repositories claimed blocked; do
    printf '%-9s %-34s %-45s %s\n' "$state" "$feature" "$counts" "$repositories"
    [ "$claimed" = - ] || printf '  claimed: %s\n' "$claimed"
    [ "$blocked" = - ] || printf '  blocked: %s\n' "$blocked"
  done
