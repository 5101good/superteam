#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PARSER="$SCRIPT_DIR/frontmatter.awk"
. "$SCRIPT_DIR/git.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  frontmatter.sh validate <file> [prd|spec|ticket]
  frontmatter.sh get <file> <key> [prd|spec|ticket]
  frontmatter.sh get-list <file> <key> [prd|spec|ticket]
  frontmatter.sh set <file> <key> <value>
  frontmatter.sh set-list <file> <key> <comma-separated-values>
  frontmatter.sh branch-get <file> <repository> <field>
  frontmatter.sh branch-repositories <ticket-file>
  frontmatter.sh branch-set <file> <repository> <field> <value>
  frontmatter.sh batch <file> <operations-file>
  frontmatter.sh replace-result <ticket-file> <result-file>
  frontmatter.sh install <target-file> <candidate-file> <prd|spec>
  frontmatter.sh lock-path <file>
EOF
  exit 2
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  return 1
}

reject_control_value() {
  value=$1
  label=$2
  case "$value" in
    *$'\n'*|*$'\r'*|*$'\t'*) fail "$label contains an unsupported control character."; return 1 ;;
  esac
}

schema_for() {
  case "$(basename "$1")" in
    prd.md) printf '%s\n' prd ;;
    spec.md) printf '%s\n' spec ;;
    *) printf '%s\n' ticket ;;
  esac
}

validate_file_shape() {
  target=$1
  [ ! -L "$target" ] && [ -f "$target" ] || {
    fail 'workflow document must be a regular file.'
    return 1
  }
  if LC_ALL=C tr -d '\n\t' < "$target" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail 'workflow document contains an unsupported control byte.'
    return 1
  fi
  final_byte=$(tail -c 1 "$target")
  [ -z "$final_byte" ] || {
    fail 'workflow document must end with a newline.'
    return 1
  }
}

run_parser() {
  mode=$1
  schema=$2
  target=$3
  shift 3
  validate_file_shape "$target" || return 1
  LC_ALL=C awk -v mode="$mode" -v schema="$schema" "$@" -f "$PARSER" "$target"
}

absolute_file() {
  target=$1
  directory=$(dirname "$target")
  leaf=$(basename "$target")
  directory=$(cd -P -- "$directory" && pwd -P) || return 1
  printf '%s/%s\n' "$directory" "$leaf"
}

git_common_directory() {
  target=$1
  directory=$(dirname "$target")
  root=$(isolated_git -C "$directory" rev-parse --show-toplevel 2>/dev/null) || {
    fail 'workflow document must be inside a Git Repository.'
    return 1
  }
  common=$(isolated_git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common=$root/$common ;;
  esac
  common=$(cd -P -- "$common" && pwd -P) || return 1
  printf '%s\n' "$common"
}

lock_path_for() {
  target=$(absolute_file "$1") || return 1
  common=$(git_common_directory "$target") || return 1
  set -- $(printf '%s' "$target" | cksum)
  printf '%s/superteam-data-locks/%s-%s.lock\n' "$common" "$1" "$2"
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

file_identity() {
  target=$1
  if inode=$(stat -f '%d:%i' "$target" 2>/dev/null); then
    :
  else
    inode=$(stat -c '%d:%i' "$target") || return 1
  fi
  set -- $(cksum "$target")
  printf '%s:%s:%s\n' "$inode" "$1" "$2"
}

cleanup_mutation() {
  [ -z "${MUTATION_TEMP:-}" ] || rm -f -- "$MUTATION_TEMP"
  [ -z "${MUTATION_STAGE:-}" ] || rm -f -- "$MUTATION_STAGE"
  if [ "${MUTATION_LOCK_ACQUIRED:-false}" = true ] && [ -n "${MUTATION_LOCK:-}" ]; then
    rmdir -- "$MUTATION_LOCK" 2>/dev/null || true
    mutation_lock_parent=$(dirname "$MUTATION_LOCK")
    rmdir -- "$mutation_lock_parent" 2>/dev/null || true
    MUTATION_LOCK_ACQUIRED=false
  fi
}

cleanup_all() {
  cleanup_mutation
  if [ -n "${OPERATIONS_TEMP:-}" ]; then
    rm -f -- "$OPERATIONS_TEMP"
  fi
}

begin_mutation() {
  target=$1
  validate_file_shape "$target" || return 1
  MUTATION_TARGET=$(absolute_file "$target") || return 1
  MUTATION_LOCK_ACQUIRED=false
  MUTATION_BEFORE=$(file_identity "$MUTATION_TARGET") || return 1
  MUTATION_MODE=$(file_mode "$MUTATION_TARGET") || return 1
  MUTATION_LOCK=$(lock_path_for "$MUTATION_TARGET") || return 1
  mutation_lock_parent=$(dirname "$MUTATION_LOCK")
  mkdir -p -- "$mutation_lock_parent" || return 1
  if ! mkdir -- "$MUTATION_LOCK" 2>/dev/null; then
    fail 'another workflow data writer is active.'
    return 1
  fi
  MUTATION_LOCK_ACQUIRED=true
  MUTATION_TEMP=$(dirname "$MUTATION_TARGET")/.$(basename "$MUTATION_TARGET").superteam-write.$$
  MUTATION_STAGE=''
  [ ! -e "$MUTATION_TEMP" ] && [ ! -L "$MUTATION_TEMP" ] || {
    fail 'workflow data temporary path already exists.'
    cleanup_mutation
    return 1
  }
  trap 'exit 130' HUP INT TERM
  trap cleanup_all EXIT
  mutation_current=$(file_identity "$MUTATION_TARGET") || return 1
  [ "$mutation_current" = "$MUTATION_BEFORE" ] || {
    fail 'workflow document changed before the update lock was acquired.'
    return 1
  }
}

finish_mutation() {
  schema=$1
  run_parser validate "$schema" "$MUTATION_TEMP" >/dev/null || return 1
  chmod "$MUTATION_MODE" "$MUTATION_TEMP" || return 1
  [ ! -L "$MUTATION_TARGET" ] && [ -f "$MUTATION_TARGET" ] &&
    mutation_current=$(file_identity "$MUTATION_TARGET") || return 1
    [ "$mutation_current" = "$MUTATION_BEFORE" ] || {
      fail 'workflow document changed concurrently; update was not applied.'
      return 1
    }
  mv -f -- "$MUTATION_TEMP" "$MUTATION_TARGET" || return 1
  MUTATION_TEMP=''
  cleanup_mutation
  MUTATION_LOCK=''
}

install_document() {
  local install_target=$1 install_candidate=$2 install_schema=$3
  local target_existed candidate_before candidate_current mutation_current mutation_lock_parent
  local candidate_created_at target_created_at
  case "$install_schema" in prd|spec) ;; *) usage ;; esac

  validate_file_shape "$install_candidate" || return 1
  run_parser validate "$install_schema" "$install_candidate" >/dev/null || return 1
  MUTATION_TARGET=$(absolute_file "$install_target") || return 1
  install_candidate=$(absolute_file "$install_candidate") || return 1
  [ "$install_candidate" != "$MUTATION_TARGET" ] || {
    fail 'candidate and target must be different files.'
    return 1
  }

  MUTATION_TEMP=''
  MUTATION_STAGE=''
  MUTATION_LOCK=''
  MUTATION_LOCK_ACQUIRED=false
  target_existed=false
  if [ -e "$MUTATION_TARGET" ] || [ -L "$MUTATION_TARGET" ]; then
    validate_file_shape "$MUTATION_TARGET" || return 1
    target_existed=true
    MUTATION_BEFORE=$(file_identity "$MUTATION_TARGET") || return 1
    MUTATION_MODE=$(file_mode "$MUTATION_TARGET") || return 1
  else
    MUTATION_BEFORE=''
    MUTATION_MODE=644
  fi

  MUTATION_LOCK=$(lock_path_for "$MUTATION_TARGET") || return 1
  mutation_lock_parent=$(dirname "$MUTATION_LOCK")
  mkdir -p -- "$mutation_lock_parent" || return 1
  if ! mkdir -- "$MUTATION_LOCK" 2>/dev/null; then
    fail 'another workflow data writer is active.'
    return 1
  fi
  MUTATION_LOCK_ACQUIRED=true
  MUTATION_TEMP=$(dirname "$MUTATION_TARGET")/.$(basename "$MUTATION_TARGET").superteam-write.$$
  [ ! -e "$MUTATION_TEMP" ] && [ ! -L "$MUTATION_TEMP" ] || {
    fail 'workflow data temporary path already exists.'
    cleanup_mutation
    return 1
  }
  trap 'exit 130' HUP INT TERM
  trap cleanup_all EXIT

  if [ "$target_existed" = true ]; then
    [ ! -L "$MUTATION_TARGET" ] && [ -f "$MUTATION_TARGET" ] &&
      mutation_current=$(file_identity "$MUTATION_TARGET") || return 1
    [ "$mutation_current" = "$MUTATION_BEFORE" ] || {
      fail 'workflow document changed before the update lock was acquired.'
      return 1
    }
    candidate_created_at=$(run_parser get "$install_schema" "$install_candidate" -v query=created_at) || return 1
    target_created_at=$(run_parser get "$install_schema" "$MUTATION_TARGET" -v query=created_at) || return 1
    [ "$candidate_created_at" = "$target_created_at" ] || {
      fail 'created_at must match the Current Contract during revision.'
      return 1
    }
  fi

  candidate_before=$(file_identity "$install_candidate") || return 1
  cp "$install_candidate" "$MUTATION_TEMP" || return 1
  candidate_current=$(file_identity "$install_candidate") || return 1
  [ "$candidate_current" = "$candidate_before" ] || {
    fail 'candidate changed while it was being staged.'
    return 1
  }
  run_parser validate "$install_schema" "$MUTATION_TEMP" >/dev/null || return 1
  chmod "$MUTATION_MODE" "$MUTATION_TEMP" || return 1

  if [ "$target_existed" = true ]; then
    [ ! -L "$MUTATION_TARGET" ] && [ -f "$MUTATION_TARGET" ] &&
      mutation_current=$(file_identity "$MUTATION_TARGET") || return 1
    [ "$mutation_current" = "$MUTATION_BEFORE" ] || {
      fail 'workflow document changed concurrently; update was not applied.'
      return 1
    }
  else
    [ ! -e "$MUTATION_TARGET" ] && [ ! -L "$MUTATION_TARGET" ] || {
      fail 'workflow document appeared concurrently; update was not applied.'
      return 1
    }
  fi

  mv -f -- "$MUTATION_TEMP" "$MUTATION_TARGET" || return 1
  MUTATION_TEMP=''
  cleanup_mutation
  MUTATION_LOCK=''
  trap - EXIT HUP INT TERM
}

result_payload_is_safe() {
  result=$1
  if grep -q '^## Result[[:space:]]*$' "$result"; then
    fail 'Result payload must not contain another Result heading.'
    return 1
  fi
}

ticket_result_shape_is_valid() {
  candidate=$1
  [ "$(grep -c '^## Result[[:space:]]*$' "$candidate" || true)" -eq 1 ] || {
    fail 'ticket must contain exactly one Result section.'
    return 1
  }
}

render_update() {
  target=$1
  schema=$2
  operations=$3
  begin_mutation "$target" || return 1
  run_parser render "$schema" "$MUTATION_TARGET" -v operations="$operations" > "$MUTATION_TEMP" || return 1
  finish_mutation "$schema"
}

command=${1:-}
[ -n "$command" ] || usage
shift

case "$command" in
  validate)
    target=${1:-}
    [ -n "$target" ] && [ "$#" -le 2 ] || usage
    schema=${2:-$(schema_for "$target")}
    run_parser validate "$schema" "$target"
    ;;
  get|get-list)
    target=${1:-}; key=${2:-}
    [ -n "$target" ] && [ -n "$key" ] && [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
    schema=${3:-$(schema_for "$target")}
    case "$schema" in prd|spec|ticket) ;; *) usage ;; esac
    run_parser "$command" "$schema" "$target" -v query="$key"
    ;;
  branch-get)
    target=${1:-}; repository=${2:-}; field=${3:-}
    [ -n "$target" ] && [ -n "$repository" ] && [ -n "$field" ] && [ "$#" -eq 3 ] || usage
    run_parser branch-get ticket "$target" -v branch_repository="$repository" -v branch_field="$field"
    ;;
  branch-repositories)
    target=${1:-}
    [ -n "$target" ] && [ "$#" -eq 1 ] || usage
    run_parser branch-repositories ticket "$target"
    ;;
  set|set-list|branch-set)
    target=${1:-}
    [ -n "$target" ] || usage
    schema=$(schema_for "$target")
    operations=$(mktemp "${TMPDIR:-/tmp}/superteam-data-operations.XXXXXX") || exit 1
    OPERATIONS_TEMP=$operations
    trap 'exit 130' HUP INT TERM
    trap cleanup_all EXIT
    case "$command" in
      set)
        [ "$#" -eq 3 ] || usage
        reject_control_value "$2" 'frontmatter key' || exit 1
        reject_control_value "$3" 'frontmatter value' || exit 1
        printf 'set\t%s\t%s\n' "$2" "$3" > "$operations"
        ;;
      set-list)
        [ "$#" -eq 3 ] || usage
        reject_control_value "$2" 'frontmatter key' || exit 1
        reject_control_value "$3" 'frontmatter list' || exit 1
        printf 'list\t%s\t%s\n' "$2" "$3" > "$operations"
        ;;
      branch-set)
        [ "$#" -eq 4 ] || usage
        reject_control_value "$2" 'Repository ID' || exit 1
        reject_control_value "$3" 'Repository branch field' || exit 1
        reject_control_value "$4" 'Repository branch value' || exit 1
        printf 'branch\t%s\t%s\t%s\n' "$2" "$3" "$4" > "$operations"
        ;;
    esac
    render_update "$target" "$schema" "$operations"
    rm -f -- "$operations"
    OPERATIONS_TEMP=''
    trap - EXIT HUP INT TERM
    ;;
  batch)
    target=${1:-}; operations=${2:-}
    [ -n "$target" ] && [ -f "$operations" ] && [ "$#" -eq 2 ] || usage
    schema=$(schema_for "$target")
    render_update "$target" "$schema" "$operations"
    ;;
  batch-result)
    target=${1:-}; operations=${2:-}; result=${3:-}
    [ -n "$target" ] && [ -f "$operations" ] && [ -f "$result" ] && [ "$#" -eq 3 ] || usage
    result_payload_is_safe "$result"
    run_parser validate ticket "$target" >/dev/null
    [ "$(grep -c '^## Result[[:space:]]*$' "$target" || true)" -eq 1 ] || {
      fail 'ticket must contain exactly one Result section.'
      exit 1
    }
    begin_mutation "$target"
    MUTATION_STAGE=$MUTATION_TEMP.stage
    run_parser render ticket "$MUTATION_TARGET" -v operations="$operations" > "$MUTATION_STAGE"
    awk '{ print } /^## Result[[:space:]]*$/ { exit }' "$MUTATION_STAGE" > "$MUTATION_TEMP"
    printf '\n' >> "$MUTATION_TEMP"
    sed -e '${/^$/d;}' "$result" >> "$MUTATION_TEMP"
    final_byte=$(tail -c 1 "$MUTATION_TEMP")
    [ -z "$final_byte" ] || printf '\n' >> "$MUTATION_TEMP"
    rm -f -- "$MUTATION_STAGE"
    MUTATION_STAGE=''
    ticket_result_shape_is_valid "$MUTATION_TEMP"
    finish_mutation ticket
    ;;
  replace-result)
    target=${1:-}; result=${2:-}
    [ -n "$target" ] && [ -f "$result" ] && [ "$#" -eq 2 ] || usage
    result_payload_is_safe "$result"
    run_parser validate ticket "$target" >/dev/null
    [ "$(grep -c '^## Result[[:space:]]*$' "$target" || true)" -eq 1 ] || {
      fail 'ticket must contain exactly one Result section.'
      exit 1
    }
    begin_mutation "$target"
    awk '{ print } /^## Result[[:space:]]*$/ { exit }' "$MUTATION_TARGET" > "$MUTATION_TEMP"
    printf '\n' >> "$MUTATION_TEMP"
    sed -e '${/^$/d;}' "$result" >> "$MUTATION_TEMP"
    final_byte=$(tail -c 1 "$MUTATION_TEMP")
    [ -z "$final_byte" ] || printf '\n' >> "$MUTATION_TEMP"
    ticket_result_shape_is_valid "$MUTATION_TEMP"
    finish_mutation ticket
    ;;
  install)
    target=${1:-}; candidate=${2:-}; schema=${3:-}
    [ -n "$target" ] && [ -n "$candidate" ] && [ -n "$schema" ] && [ "$#" -eq 3 ] || usage
    install_document "$target" "$candidate" "$schema"
    ;;
  lock-path)
    target=${1:-}
    [ -n "$target" ] && [ "$#" -eq 1 ] || usage
    lock_path_for "$target"
    ;;
  *) usage ;;
esac
