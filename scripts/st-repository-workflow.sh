#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY=$(cd "$(dirname "$0")" && pwd -P)
SNAPSHOT="$SCRIPT_DIRECTORY/st-project-snapshot.sh"
FRONTMATTER="$SCRIPT_DIRECTORY/lib/frontmatter.sh"
WORKTREE="$SCRIPT_DIRECTORY/st-worktree.sh"
INTEGRATE="$SCRIPT_DIRECTORY/st-integrate.sh"
. "$SCRIPT_DIRECTORY/lib/git.sh"
STATE_PENDING=''
PREPARE_PENDING=''

usage() {
  cat >&2 <<'EOF'
Usage:
  st-repository-workflow.sh repositories <ticket-file>
  st-repository-workflow.sh start <ticket-file>
  st-repository-workflow.sh prepare <ticket-file> <state-file>
  st-repository-workflow.sh promote <ticket-file> <state-file>

Runs the local multi-Repository worktree and integration seam. Repository IDs
come only from the ticket and the validated Project Snapshot. Prepare completes
for every declared Repository before promote can advance any feature branch.
Promotion state is recoverable and contains only IDs, branch names, and heads.
No command clones, pulls, pushes, creates a remote, or changes a remote item.
EOF
  exit 2
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
}

reject_control_value() {
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*) fail "$2 contains an unsupported control character."; return 1 ;;
  esac
}

absolute_file() {
  local target=$1 parent leaf
  parent=$(dirname -- "$target")
  leaf=$(basename -- "$target")
  [ -n "$leaf" ] && [ "$leaf" != . ] && [ "$leaf" != .. ] || return 1
  parent=$(cd -P -- "$parent" && pwd -P) || return 1
  printf '%s/%s\n' "$parent" "$leaf"
}

load_ticket() {
  local input=$1 status ticket_directory feature_candidate repository_id repository_root
  reject_control_value "$input" 'ticket path' || return 1
  [ -f "$input" ] && [ ! -L "$input" ] || {
    fail "ticket file not found or unsafe: $input"
    return 1
  }
  TICKET_FILE=$(absolute_file "$input") || return 1
  ticket_directory=$(dirname "$TICKET_FILE")
  feature_candidate=$(dirname "$ticket_directory")
  FEATURE_DIRECTORY=$(cd -P -- "$feature_candidate" && pwd -P) || return 1
  PROJECT_ROOT=$(bash "$SNAPSHOT" root "$FEATURE_DIRECTORY") || return 1
  bash "$FRONTMATTER" validate "$TICKET_FILE" ticket >/dev/null || return 1
  TICKET_ID=$(bash "$FRONTMATTER" get "$TICKET_FILE" id ticket) || return 1
  printf '%s\n' "$TICKET_ID" | LC_ALL=C grep -Eq '^[0-9][0-9]$' || {
    fail 'ticket ID must contain exactly two digits.'
    return 1
  }
  FEATURE_KEY=$(basename "$FEATURE_DIRECTORY")
  printf '%s\n' "$FEATURE_KEY" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || {
    fail 'feature key cannot be represented in a branch name.'
    return 1
  }
  status=$(bash "$FRONTMATTER" get "$TICKET_FILE" status ticket) || return 1
  case "$status" in ready-for-agent|claimed) ;; *)
    fail "ticket is not runnable: status=$status"
    return 1
  esac

  REPOSITORY_LIST=$(mktemp "${TMPDIR:-/tmp}/superteam-ticket-repositories.XXXXXX") || return 1
  TICKET_REPOSITORIES=$(mktemp "${TMPDIR:-/tmp}/superteam-ticket-declarations.XXXXXX") || {
    rm -f -- "$REPOSITORY_LIST"
    return 1
  }
  bash "$FRONTMATTER" get-list "$TICKET_FILE" repositories ticket > "$TICKET_REPOSITORIES"
  while IFS= read -r repository_id; do
    [ -n "$repository_id" ] || continue
    if grep -qxF -- "$repository_id" "$TICKET_REPOSITORIES"; then
      printf '%s\n' "$repository_id" >> "$REPOSITORY_LIST"
    fi
  done < <(bash "$SNAPSHOT" repositories "$PROJECT_ROOT")
  [ "$(wc -l < "$REPOSITORY_LIST" | tr -d ' ')" = \
    "$(wc -l < "$TICKET_REPOSITORIES" | tr -d ' ')" ] || {
    fail 'ticket Repository declarations do not match the current Project Snapshot.'
    return 1
  }
  REPOSITORY_ROOTS=$(mktemp "${TMPDIR:-/tmp}/superteam-ticket-roots.XXXXXX") || return 1
  while IFS= read -r repository_id; do
    repository_root=$(bash "$SNAPSHOT" repository-root "$repository_id" "$PROJECT_ROOT") || return 1
    printf '%s\t%s\n' "$repository_id" "$repository_root" >> "$REPOSITORY_ROOTS"
  done < "$REPOSITORY_LIST"
}

cleanup_ticket() {
  local temporary
  for temporary in "${REPOSITORY_LIST:-}" "${TICKET_REPOSITORIES:-}" "${REPOSITORY_ROOTS:-}"; do
    [ -z "$temporary" ] || rm -f -- "$temporary"
  done
}

cleanup_pending_state() {
  [ -z "$STATE_PENDING" ] || rm -f -- "$STATE_PENDING"
  [ -z "$PREPARE_PENDING" ] || rm -f -- "$PREPARE_PENDING"
}

cleanup_workflow() {
  cleanup_pending_state
  cleanup_ticket
}

interrupt_workflow() {
  cleanup_workflow
  exit 130
}

repository_root_for() {
  awk -F '\t' -v wanted="$1" '
    $1 == wanted { print substr($0, length($1) + 2); found++ }
    END { if (found != 1) exit 1 }
  ' "$REPOSITORY_ROOTS"
}

feature_branch_for() {
  printf 'superteam/%s\n' "$FEATURE_KEY"
}

ticket_branch_for() {
  printf 'superteam/%s-ticket-%s-%s\n' "$FEATURE_KEY" "$TICKET_ID" "$1"
}

integration_branch_for() {
  printf 'superteam/%s-integrate-%s-%s\n' "$FEATURE_KEY" "$TICKET_ID" "$1"
}

topology_for() {
  local repository=$1 superproject
  [ "$repository" != "$PROJECT_ROOT" ] || { printf '%s\n' ROOT; return 0; }
  superproject=$(superproject_for "$repository") || return 1
  [ -z "$superproject" ] || { printf '%s\n' SUBMODULE; return 0; }
  case "$repository" in "$PROJECT_ROOT"/*) printf '%s\n' NESTED ;; *) printf '%s\n' EXTERNAL ;; esac
}

superproject_for() {
  local repository=$1 superproject
  superproject=$(isolated_git -C "$repository" rev-parse --show-superproject-working-tree 2>/dev/null || true)
  [ -n "$superproject" ] || return 0
  cd -P -- "$superproject" && pwd -P
}

print_repository() {
  local repository_id=$1 repository=$2 topology superproject worktree_path=${3:-}
  topology=$(topology_for "$repository") || return 1
  printf 'REPOSITORY: %s\n' "$repository_id"
  printf 'REAL_GIT_ROOT: %s\n' "$repository"
  printf 'TOPOLOGY: %s\n' "$topology"
  if [ "$topology" = SUBMODULE ]; then
    superproject=$(superproject_for "$repository") || return 1
    printf 'SUPERPROJECT: %s\n' "$superproject"
    if ! superproject_state=$(git_worktree_state "$superproject"); then
      printf '%s\n' 'SUPERPROJECT_WORKTREE: ERROR'
      fail "could not inspect submodule parent worktree: $superproject"
      return 1
    fi
    printf '%s\n' "SUPERPROJECT_WORKTREE: $superproject_state"
  fi
  [ -z "$worktree_path" ] || printf 'TICKET_WORKTREE: %s\n' "$worktree_path"
}

preflight_repositories() {
  local repository_id repository
  while IFS= read -r repository_id; do
    repository=$(repository_root_for "$repository_id") || return 1
    print_repository "$repository_id" "$repository"
  done < "$REPOSITORY_LIST"
}

state_target() {
  local input=$1 repository_id repository repository_prefix
  reject_control_value "$input" 'state path' || return 1
  STATE_FILE=$(absolute_file "$input") || {
    fail 'state file parent directory must already exist.'
    return 1
  }
  state_file_type_is_safe || return 1
  while IFS= read -r repository_id; do
    repository=$(repository_root_for "$repository_id") || return 1
    repository_prefix=$repository/
    if [ "$STATE_FILE" = "$repository" ]; then
      fail "state file must be outside every Repository: $repository_id"
      return 1
    fi
    case "$STATE_FILE" in "$repository_prefix"*)
      fail "state file must be outside every Repository: $repository_id"
      return 1
      ;;
    esac
  done < "$REPOSITORY_LIST"
}

state_file_type_is_safe() {
  if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
    [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || {
      fail 'state target must be absent or a regular file.'
      return 1
    }
  fi
}

state_replace() {
  local source=$1 state_parent
  state_file_type_is_safe || return 1
  state_parent=$(dirname "$STATE_FILE")
  STATE_PENDING=$(mktemp "$state_parent/.superteam-integration-state.XXXXXX") || return 1
  if ! cp -- "$source" "$STATE_PENDING" || ! mv -- "$STATE_PENDING" "$STATE_FILE"; then
    rm -f -- "$STATE_PENDING"
    STATE_PENDING=''
    return 1
  fi
  STATE_PENDING=''
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]
}

state_mark_promoted() {
  local wanted=$1 state_parent
  state_file_type_is_safe || return 1
  state_parent=$(dirname "$STATE_FILE")
  STATE_PENDING=$(mktemp "$state_parent/.superteam-integration-state.XXXXXX") || return 1
  awk -F '\t' -v OFS='\t' -v wanted="$wanted" '
    $1 == wanted { $8 = "promoted"; changed++ }
    { print }
    END { if (changed != 1) exit 1 }
  ' "$STATE_FILE" > "$STATE_PENDING" || {
    rm -f -- "$STATE_PENDING"
    STATE_PENDING=''
    return 1
  }
  if ! mv -- "$STATE_PENDING" "$STATE_FILE"; then
    rm -f -- "$STATE_PENDING"
    STATE_PENDING=''
    return 1
  fi
  STATE_PENDING=''
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]
}

validate_state() {
  local expected_ids actual_ids
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || {
    fail "integration state file not found or unsafe: $STATE_FILE"
    return 1
  }
  awk -F '\t' '
    NF != 8 { exit 1 }
    $1 !~ /^[a-z0-9][a-z0-9._-]*$/ { exit 1 }
    $2 !~ /^superteam\/[A-Za-z0-9][A-Za-z0-9._-]*$/ { exit 1 }
    $3 !~ /^superteam\/[A-Za-z0-9][A-Za-z0-9._-]*$/ { exit 1 }
    $4 !~ /^superteam\/[A-Za-z0-9][A-Za-z0-9._-]*$/ { exit 1 }
    $5 !~ /^[0-9a-f]+$/ || $6 !~ /^[0-9a-f]+$/ || $7 !~ /^[0-9a-f]+$/ { exit 1 }
    $8 != "pending" && $8 != "promoted" { exit 1 }
  ' "$STATE_FILE" || { fail 'integration state file is invalid.'; return 1; }
  expected_ids=$(sed -n 'p' "$REPOSITORY_LIST")
  actual_ids=$(cut -f1 "$STATE_FILE")
  [ "$actual_ids" = "$expected_ids" ] || {
    fail 'integration state Repository order does not match the current ticket and Project Snapshot.'
    return 1
  }
}

report_submodule_parents() {
  local repository_id repository topology superproject state
  while IFS= read -r repository_id; do
    repository=$(repository_root_for "$repository_id") || return 1
    topology=$(topology_for "$repository") || return 1
    [ "$topology" = SUBMODULE ] || continue
    superproject=$(superproject_for "$repository") || return 1
    if ! state=$(git_worktree_state "$superproject"); then
      fail "could not inspect submodule parent worktree: $superproject"
      return 1
    fi
    printf 'SUBMODULE_PARENT_STATUS: repository=%s superproject=%s worktree=%s\n' \
      "$repository_id" "$superproject" "$state"
  done < "$REPOSITORY_LIST"
}

reject_gitlink_delta() {
  local repository_id=$1 repository=$2 before=$3 after=$4
  if isolated_git -C "$repository" diff --raw --no-renames "$before" "$after" -- |
    awk '
      substr($1, 2) == "160000" || $2 == "160000" { found = 1 }
      END { exit(found ? 0 : 1) }
    '
  then
    fail "parent gitlink delta is not allowed: repository=$repository_id before=$before after=$after"
    return 1
  fi
}

start_set() {
  local repository_id repository feature_branch ticket_branch ticket_path ticket_head state
  preflight_repositories
  while IFS= read -r repository_id; do
    repository=$(repository_root_for "$repository_id") || return 1
    if ! state=$(git_worktree_state "$repository"); then
      fail "could not inspect Repository worktree: id=$repository_id root=$repository"
      return 1
    fi
    [ "$state" = CLEAN ] || {
      fail "Repository baseline is dirty: id=$repository_id root=$repository"
      return 3
    }
  done < "$REPOSITORY_LIST"
  feature_branch=$(feature_branch_for)
  while IFS= read -r repository_id; do
    repository=$(repository_root_for "$repository_id") || return 1
    ticket_branch=$(ticket_branch_for "$repository_id")
    bash "$WORKTREE" prepare-feature "$repository" "$feature_branch" >/dev/null
    ticket_path=$(bash "$WORKTREE" stable-path "$repository" "$FEATURE_KEY" \
      "$TICKET_ID" "$repository_id" ticket) || return 1
    bash "$WORKTREE" add-ticket "$repository" "$feature_branch" "$ticket_branch" \
      "$ticket_path" >/dev/null
    printf 'STARTED_REPOSITORY: %s\nTICKET_WORKTREE: %s\n' "$repository_id" "$ticket_path"
    ticket_head=$(isolated_git -C "$repository" rev-parse "refs/heads/$ticket_branch")
    printf 'FEATURE_BRANCH: %s\nTICKET_BRANCH: %s\nTICKET_HEAD: %s\n' "$feature_branch" \
      "$ticket_branch" "$ticket_head"
  done < "$REPOSITORY_LIST"
  report_submodule_parents
}

prepare_set() {
  local repository_id repository feature_branch ticket_branch integration_branch
  local integration_path state_temporary base ticket_head prepared return_code
  state_target "$1" || return 1
  preflight_repositories
  feature_branch=$(feature_branch_for)
  while IFS= read -r repository_id; do
    repository=$(repository_root_for "$repository_id") || return 1
    ticket_branch=$(ticket_branch_for "$repository_id")
    integration_branch=$(integration_branch_for "$repository_id")
    for branch in "$feature_branch" "$ticket_branch"; do
      isolated_git -C "$repository" show-ref --verify --quiet "refs/heads/$branch" || {
        fail "required branch is missing: repository=$repository_id branch=$branch"
        printf '%s\n' 'PREPARE_STATUS: FAILED'
        return 1
      }
    done
    base=$(isolated_git -C "$repository" rev-parse "refs/heads/$feature_branch")
    ticket_head=$(isolated_git -C "$repository" rev-parse "refs/heads/$ticket_branch")
    reject_gitlink_delta "$repository_id" "$repository" "$base" "$ticket_head" || {
      printf 'PREPARE_STATUS: FAILED\nFAILED_REPOSITORY: %s\n' "$repository_id"
      return 1
    }
  done < "$REPOSITORY_LIST"

  PREPARE_PENDING=$(mktemp "${TMPDIR:-/tmp}/superteam-integration-state.XXXXXX") || return 1
  state_temporary=$PREPARE_PENDING
  while IFS= read -r repository_id; do
    repository=$(repository_root_for "$repository_id") || { rm -f -- "$state_temporary"; return 1; }
    ticket_branch=$(ticket_branch_for "$repository_id")
    integration_branch=$(integration_branch_for "$repository_id")
    integration_path=$(bash "$WORKTREE" stable-path "$repository" "$FEATURE_KEY" \
      "$TICKET_ID" "$repository_id" integration) || { rm -f -- "$state_temporary"; return 1; }
    base=$(isolated_git -C "$repository" rev-parse "refs/heads/$feature_branch")
    ticket_head=$(isolated_git -C "$repository" rev-parse "refs/heads/$ticket_branch")
    set +e
    bash "$INTEGRATE" prepare "$repository" "$feature_branch" "$ticket_branch" \
      "$integration_branch" "$integration_path"
    return_code=$?
    set -e
    if [ "$return_code" -ne 0 ]; then
      rm -f -- "$state_temporary"
      PREPARE_PENDING=''
      printf 'PREPARE_STATUS: FAILED\nFAILED_REPOSITORY: %s\n' "$repository_id"
      return "$return_code"
    fi
    prepared=$(isolated_git -C "$repository" rev-parse "refs/heads/$integration_branch")
    reject_gitlink_delta "$repository_id" "$repository" "$base" "$prepared" || {
      rm -f -- "$state_temporary"
      PREPARE_PENDING=''
      printf 'PREPARE_STATUS: FAILED\nFAILED_REPOSITORY: %s\n' "$repository_id"
      return 1
    }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tpending\n' "$repository_id" \
      "$feature_branch" "$ticket_branch" "$integration_branch" "$base" "$ticket_head" \
      "$prepared" >> "$state_temporary"
  done < "$REPOSITORY_LIST"
  if ! state_replace "$state_temporary"; then
    rm -f -- "$state_temporary"
    PREPARE_PENDING=''
    printf 'PREPARE_STATUS: FAILED\nREASON: STATE_WRITE_FAILED\nSTATE: %s\n' "$STATE_FILE"
    return 1
  fi
  rm -f -- "$state_temporary"
  PREPARE_PENDING=''
  printf 'PREPARE_STATUS: COMPLETE\nSTATE: %s\n' "$STATE_FILE"
  report_submodule_parents
}

promote_set() {
  local repository_id feature_branch ticket_branch integration_branch base ticket_head prepared state
  local repository actual return_code recovery_changed=false expected_ticket_branch expected_integration_branch
  state_target "$1" || return 1
  validate_state || return 1
  preflight_repositories

  while IFS=$'\t' read -r repository_id feature_branch ticket_branch integration_branch base ticket_head prepared state; do
    repository=$(repository_root_for "$repository_id") || return 1
    expected_ticket_branch=$(ticket_branch_for "$repository_id")
    expected_integration_branch=$(integration_branch_for "$repository_id")
    [ "$feature_branch" = "$(feature_branch_for)" ] &&
      [ "$ticket_branch" = "$expected_ticket_branch" ] &&
      [ "$integration_branch" = "$expected_integration_branch" ] || {
      fail "integration state branch names do not match Repository: $repository_id"
      return 1
    }
    actual=$(isolated_git -C "$repository" rev-parse "refs/heads/$feature_branch" 2>/dev/null) || {
      fail "feature branch is missing for Repository: $repository_id"
      return 3
    }
    [ "$(isolated_git -C "$repository" rev-parse "refs/heads/$integration_branch" 2>/dev/null)" = "$prepared" ] || {
      fail "prepared head changed for Repository: $repository_id"
      return 3
    }
    [ "$(isolated_git -C "$repository" rev-parse "refs/heads/$ticket_branch" 2>/dev/null)" = "$ticket_head" ] &&
      isolated_git -C "$repository" merge-base --is-ancestor "$ticket_head" "$prepared" || {
      fail "ticket head changed or is absent from prepared integration: $repository_id"
      return 3
    }
    reject_gitlink_delta "$repository_id" "$repository" "$base" "$prepared" || {
      printf 'PROMOTE_STATUS: PARTIAL\nFAILED_REPOSITORY: %s\nREASON: GITLINK_DELTA\nSTATE: %s\n' \
        "$repository_id" "$STATE_FILE"
      return 3
    }
    if [ "$state" = promoted ]; then
      [ "$actual" = "$prepared" ] || {
        fail "promoted Repository changed and needs manual reconciliation: id=$repository_id recorded=$prepared actual=$actual"
        printf '%s\n' 'PROMOTE_STATUS: PARTIAL'
        return 3
      }
    elif [ "$actual" = "$prepared" ]; then
      if ! state_mark_promoted "$repository_id"; then
        printf 'PROMOTE_STATUS: PARTIAL\nFAILED_REPOSITORY: %s\nREASON: STATE_WRITE_FAILED\nSTATE: %s\n' \
          "$repository_id" "$STATE_FILE"
        report_submodule_parents || true
        return 3
      fi
      recovery_changed=true
      printf 'RECOVERED_REPOSITORY: %s\n' "$repository_id"
    elif [ "$actual" = "$base" ]; then
      isolated_git -C "$repository" merge-base --is-ancestor "$base" "$prepared" || {
        fail "prepared head is not a fast-forward for Repository: $repository_id"
        return 3
      }
    else
      fail "pending Repository changed and needs manual reconciliation: id=$repository_id expected=$base actual=$actual"
      printf '%s\n' 'PROMOTE_STATUS: PARTIAL'
      return 3
    fi
  done < "$STATE_FILE"

  [ "$recovery_changed" = false ] || validate_state
  while IFS=$'\t' read -r repository_id feature_branch ticket_branch integration_branch base ticket_head prepared state; do
    [ "$state" = pending ] || continue
    repository=$(repository_root_for "$repository_id") || return 1
    set +e
    bash "$INTEGRATE" promote "$repository" "$feature_branch" "$integration_branch" "$base"
    return_code=$?
    set -e
    if [ "$return_code" -ne 0 ]; then
      printf 'PROMOTE_STATUS: PARTIAL\nFAILED_REPOSITORY: %s\nSTATE: %s\n' \
        "$repository_id" "$STATE_FILE"
      return 3
    fi
    if ! state_mark_promoted "$repository_id"; then
      printf 'PROMOTE_STATUS: PARTIAL\nFAILED_REPOSITORY: %s\nREASON: STATE_WRITE_FAILED\nSTATE: %s\n' \
        "$repository_id" "$STATE_FILE"
      report_submodule_parents || true
      return 3
    fi
    printf 'PROMOTED_REPOSITORY: %s\n' "$repository_id"
  done < "$STATE_FILE"
  printf 'PROMOTE_STATUS: COMPLETE\nSTATE: %s\n' "$STATE_FILE"
  report_submodule_parents
}

command=${1:-}
[ -n "$command" ] || usage
shift
case "$command" in
  repositories|start)
    [ "$#" -eq 1 ] || usage
    load_ticket "$1" || { cleanup_workflow; exit 1; }
    trap cleanup_workflow EXIT
    trap interrupt_workflow HUP INT TERM
    if [ "$command" = repositories ]; then preflight_repositories; else start_set; fi
    ;;
  prepare|promote)
    [ "$#" -eq 2 ] || usage
    load_ticket "$1" || { cleanup_workflow; exit 1; }
    trap cleanup_workflow EXIT
    trap interrupt_workflow HUP INT TERM
    if [ "$command" = prepare ]; then prepare_set "$2"; else promote_set "$2"; fi
    ;;
  *) usage ;;
esac
