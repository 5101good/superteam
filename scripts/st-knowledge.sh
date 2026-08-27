#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
SNAPSHOT="$SCRIPT_DIR/st-project-snapshot.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  st-knowledge.sh root [project]
  st-knowledge.sh repository <repository> [project]
  st-knowledge.sh context <repository> [project]
  st-knowledge.sh adrs <repository> [project]
  st-knowledge.sh decisions [project]
  st-knowledge.sh architecture [project]
  st-knowledge.sh api [project]
  st-knowledge.sh reference [project]
  st-knowledge.sh path <relative-path> [project]

Resolve a location from a validated Project Snapshot. This command is read-only
and does not create the returned file or directory.
EOF
  exit 2
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  return 1
}

reject_control_characters() {
  case "$1" in
    *$'\n'*|*$'\r'*) fail "$2 contains an unsupported line break."; return 1 ;;
  esac
  if printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "$2 contains an unsupported control character."
    return 1
  fi
}

validate_relative_path() {
  relative_value=$1
  reject_control_characters "$relative_value" 'knowledge relative path' || return 1
  case "$relative_value" in
    ''|.|/*|~*|*/|*//*|../*|*/../*|*/..|./*|*/./*|*/.)
      fail 'knowledge path must be a normalized relative path without dot segments.'
      return 2
      ;;
  esac
}

verify_existing_components() {
  component_root=$1
  component_path=$2
  component_remaining=$component_path
  component_current=$component_root
  while [ -n "$component_remaining" ]; do
    case "$component_remaining" in
      */*)
        component_name=${component_remaining%%/*}
        component_remaining=${component_remaining#*/}
        ;;
      *)
        component_name=$component_remaining
        component_remaining=''
        ;;
    esac
    component_current=$component_current/$component_name
    if [ -L "$component_current" ]; then
      fail 'knowledge path traverses a symbolic link.'
      return 1
    fi
    if [ -n "$component_remaining" ] && [ -e "$component_current" ] && [ ! -d "$component_current" ]; then
      fail 'knowledge path traverses a non-directory component.'
      return 1
    fi
  done
}

resolve_repository() {
  repository_id=$1
  repository_project=$2
  reject_control_characters "$repository_id" 'Repository ID' || return 2
  if ! bash "$SNAPSHOT" repository-path "$repository_id" "$repository_project" >/dev/null; then
    fail "unknown Repository ID: $repository_id"
    return 1
  fi
}

command_name=${1:-}
[ -n "$command_name" ] || usage
shift

repository_id=''
relative_path=''
case "$command_name" in
  root|decisions|architecture|api|reference)
    [ "$#" -le 1 ] || usage
    project_path=${1:-.}
    ;;
  repository|context|adrs)
    repository_id=${1:-}
    [ -n "$repository_id" ] && [ "$#" -le 2 ] || usage
    project_path=${2:-.}
    resolve_repository "$repository_id" "$project_path" || exit $?
    ;;
  path)
    relative_path=${1:-}
    [ -n "$relative_path" ] && [ "$#" -le 2 ] || usage
    project_path=${2:-.}
    validate_relative_path "$relative_path" || exit $?
    ;;
  *) usage ;;
esac

knowledge_root=$(bash "$SNAPSHOT" knowledge "$project_path") || exit 1
project_root=$(bash "$SNAPSHOT" root "$project_path") || exit 1
reject_control_characters "$knowledge_root" 'knowledge root' || exit 1
reject_control_characters "$project_root" 'Project root' || exit 1
case "$knowledge_root" in
  "$project_root"/*) knowledge_relative=${knowledge_root#"$project_root"/} ;;
  *) fail 'knowledge root is outside the Root Repository.'; exit 1 ;;
esac
validate_relative_path "$knowledge_relative" || exit $?
verify_existing_components "$project_root" "$knowledge_relative" || exit 1

case "$command_name" in
  root)
    printf '%s\n' "$knowledge_root"
    ;;
  repository)
    relative_path=repositories/$repository_id
    verify_existing_components "$knowledge_root" "$relative_path" || exit 1
    printf '%s/%s\n' "$knowledge_root" "$relative_path"
    ;;
  context)
    relative_path=repositories/$repository_id/CONTEXT.md
    verify_existing_components "$knowledge_root" "$relative_path" || exit 1
    printf '%s/%s\n' "$knowledge_root" "$relative_path"
    ;;
  adrs)
    relative_path=repositories/$repository_id/adr
    verify_existing_components "$knowledge_root" "$relative_path" || exit 1
    printf '%s/%s\n' "$knowledge_root" "$relative_path"
    ;;
  decisions|architecture|api|reference)
    relative_path=$command_name
    verify_existing_components "$knowledge_root" "$relative_path" || exit 1
    printf '%s/%s\n' "$knowledge_root" "$relative_path"
    ;;
  path)
    verify_existing_components "$knowledge_root" "$relative_path" || exit 1
    printf '%s/%s\n' "$knowledge_root" "$relative_path"
    ;;
esac
