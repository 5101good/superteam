#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
KNOWLEDGE="$SCRIPT_DIR/st-knowledge.sh"
SNAPSHOT="$SCRIPT_DIR/st-project-snapshot.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  st-context-seed.sh context <repository> [project]
  st-context-seed.sh adr <repository> [project]
  st-context-seed.sh decisions [project]
  st-context-seed.sh map [project]

Context and map writes occur only when this command is explicitly invoked.
EOF
  exit 2
}

count_adrs() {
  count_directory=$1
  ADR_COUNT=0
  for count_file in "$count_directory"/[0-9]*-*.md; do
    [ -f "$count_file" ] || continue
    ADR_COUNT=$((ADR_COUNT + 1))
  done
}

mode=${1:-}
[ -n "$mode" ] || usage
shift

case "$mode" in
  context)
    repository_id=${1:-}
    [ -n "$repository_id" ] && [ "$#" -le 2 ] || usage
    project_path=${2:-.}
    context_path=$(bash "$KNOWLEDGE" context "$repository_id" "$project_path") || exit $?
    context_directory=${context_path%/*}
    if [ -e "$context_path" ] && [ ! -f "$context_path" ]; then
      printf '%s\n' 'ERROR: Repository Context path is not a regular file.' >&2
      exit 1
    fi
    if [ ! -f "$context_path" ]; then
      mkdir -p -- "$context_directory"
      context_temporary=$(mktemp "$context_directory/.superteam-context.XXXXXX") || exit 1
      trap 'rm -f -- "$context_temporary"' EXIT HUP INT TERM
      {
        printf '# Repository Context: %s\n\n' "$repository_id"
        printf '## Scope\n\n'
        printf 'Repository ID: `%s`\n\n' "$repository_id"
        printf '<!-- Describe this Repository boundary and its relationships. -->\n\n'
        printf '## Language\n\n'
        printf '<!-- Record canonical terms and definitions only when they are resolved. -->\n'
      } > "$context_temporary"
      mv -- "$context_temporary" "$context_path"
      trap - EXIT HUP INT TERM
      printf '%s\n' "CREATED: $context_path"
      exit 3
    fi
    if ! grep -q '^## Language$' "$context_path"; then
      printf '%s\n' 'STATUS: INVALID' 'REASON: MISSING_LANGUAGE_SECTION'
      exit 4
    fi
    printf '%s\n' 'STATUS: OK'
    ;;
  adr)
    repository_id=${1:-}
    [ -n "$repository_id" ] && [ "$#" -le 2 ] || usage
    project_path=${2:-.}
    adr_directory=$(bash "$KNOWLEDGE" adrs "$repository_id" "$project_path") || exit $?
    if [ ! -d "$adr_directory" ]; then
      printf '%s\n' 'ADR_DIRECTORY: MISSING'
      exit 5
    fi
    count_adrs "$adr_directory"
    if [ "$ADR_COUNT" -eq 0 ]; then
      printf '%s\n' 'ADR_DIRECTORY: EMPTY'
      exit 6
    fi
    printf '%s\n' 'ADR_DIRECTORY: READY' "ADR_COUNT: $ADR_COUNT"
    ;;
  decisions)
    [ "$#" -le 1 ] || usage
    project_path=${1:-.}
    decision_directory=$(bash "$KNOWLEDGE" decisions "$project_path") || exit $?
    if [ ! -d "$decision_directory" ]; then
      printf '%s\n' 'DECISION_DIRECTORY: MISSING'
      exit 5
    fi
    count_adrs "$decision_directory"
    if [ "$ADR_COUNT" -eq 0 ]; then
      printf '%s\n' 'DECISION_DIRECTORY: EMPTY'
      exit 6
    fi
    printf '%s\n' 'DECISION_DIRECTORY: READY' "DECISION_COUNT: $ADR_COUNT"
    ;;
  map)
    [ "$#" -le 1 ] || usage
    project_path=${1:-.}
    knowledge_root=$(bash "$KNOWLEDGE" root "$project_path") || exit $?
    mkdir -p -- "$knowledge_root"
    map_path=$knowledge_root/CONTEXT-MAP.md
    map_temporary=$(mktemp "$knowledge_root/.superteam-context-map.XXXXXX") || exit 1
    repository_list=$(mktemp "${TMPDIR:-/tmp}/superteam-repositories.XXXXXX") || {
      rm -f -- "$map_temporary"
      exit 1
    }
    trap 'rm -f -- "$map_temporary" "$repository_list"' EXIT HUP INT TERM
    bash "$SNAPSHOT" repositories "$project_path" > "$repository_list"
    {
      printf '%s\n\n' '# Project Context Map'
      printf '%s\n\n' 'Repository Context documents are created on demand.'
      printf '%s\n' '| Repository ID | Context | Repository ADRs |'
      printf '%s\n' '|---|---|---|'
      while IFS= read -r repository_id || [ -n "$repository_id" ]; do
        [ -n "$repository_id" ] || continue
        context_path=$(bash "$KNOWLEDGE" context "$repository_id" "$project_path") || exit $?
        [ -f "$context_path" ] || continue
        adr_directory=$(bash "$KNOWLEDGE" adrs "$repository_id" "$project_path") || exit $?
        if [ -d "$adr_directory" ]; then
          adr_cell="[adr](repositories/$repository_id/adr/)"
        else
          adr_cell='-'
        fi
        printf '| %s | [CONTEXT.md](repositories/%s/CONTEXT.md) | %s |\n' \
          "$repository_id" "$repository_id" "$adr_cell"
      done < "$repository_list"
    } > "$map_temporary"
    mv -- "$map_temporary" "$map_path"
    rm -f -- "$repository_list"
    trap - EXIT HUP INT TERM
    printf '%s\n' "MAP: $map_path"
    ;;
  *) usage ;;
esac
