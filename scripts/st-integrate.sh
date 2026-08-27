#!/usr/bin/env bash
set -euo pipefail

CALLER_DIRECTORY=$(pwd -P)
SCRIPT_DIRECTORY=$(cd "$(dirname "$0")" && pwd -P)
. "$SCRIPT_DIRECTORY/lib/git.sh"
LEASE_PENDING=''
LEASE_GUARD_PENDING=''
LEASE_HEARTBEAT_PENDING=''

usage() {
  cat >&2 <<'EOF'
Usage:
  st-integrate.sh prepare <repository-root> <feature-branch> <ticket-branch> <integration-branch> <worktree-path>
  st-integrate.sh promote <repository-root> <feature-branch> <integration-branch> <expected-feature-head>
  st-integrate.sh lease-acquire <repository-root> <feature-key> --owner <owner>
  st-integrate.sh lease-heartbeat <repository-root> <feature-key> --owner <owner>
  st-integrate.sh lease-recover <repository-root> <feature-key> --owner <new-owner> --expected-owner <old-owner> --stale-after <seconds>
  st-integrate.sh lease-release <repository-root> <feature-key> --owner <owner>

Prepare merges only in an isolated local worktree. Promote is a compare-and-swap
update of the local feature ref. No command fetches, pushes, or changes a remote.
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

repository_root() {
  local candidate=$1 resolved top
  reject_control_value "$candidate" 'repository path' || return 1
  [ -d "$candidate" ] || { fail "repository not found: $candidate"; return 1; }
  resolved=$(cd -P -- "$candidate" && pwd -P) || return 1
  top=$(isolated_git -C "$resolved" rev-parse --show-toplevel 2>/dev/null) || {
    fail "not a Git worktree: $resolved"
    return 1
  }
  top=$(cd -P -- "$top" && pwd -P) || return 1
  [ "$resolved" = "$top" ] || { fail "path is not the Repository root: $resolved"; return 1; }
  printf '%s\n' "$resolved"
}

validate_branch() {
  reject_control_value "$1" 'branch name' || return 1
  isolated_git check-ref-format --branch "$1" >/dev/null 2>&1 || {
    fail "invalid branch: $1"
    return 1
  }
}

absolute_worktree_path() {
  local input=$1 candidate parent leaf
  reject_control_value "$input" 'worktree path' || return 1
  case "$input" in /*) candidate=$input ;; *) candidate=$CALLER_DIRECTORY/$input ;; esac
  leaf=$(basename -- "$candidate")
  parent=$(dirname -- "$candidate")
  case "$leaf" in ''|.|..) fail 'invalid worktree path.'; return 1 ;; esac
  [ ! -L "$candidate" ] || { fail "worktree path is a symbolic link: $candidate"; return 1; }
  mkdir -p -- "$parent" || return 1
  parent=$(cd -P -- "$parent" && pwd -P) || return 1
  printf '%s/%s\n' "$parent" "$leaf"
}

branch_worktree() {
  local repository=$1 branch=$2
  isolated_git -C "$repository" worktree list --porcelain |
    awk -v ref="refs/heads/$branch" '
      $1 == "worktree" { path=$0; sub(/^worktree /, "", path) }
      $1 == "branch" && $2 == ref { print path; exit }
    '
}

same_path() {
  local first=$1 second=$2 first_directory second_directory first_parent second_parent first_leaf second_leaf
  first_directory=$(dirname -- "$first")
  second_directory=$(dirname -- "$second")
  first_leaf=$(basename -- "$first")
  second_leaf=$(basename -- "$second")
  first_parent=$(cd -P -- "$first_directory" && pwd -P) || return 1
  second_parent=$(cd -P -- "$second_directory" && pwd -P) || return 1
  [ "$first_parent/$first_leaf" = "$second_parent/$second_leaf" ]
}

common_directory() {
  local repository=$1 common
  common=$(isolated_git -C "$repository" rev-parse --git-common-dir) || return 1
  case "$common" in /*) ;; *) common=$repository/$common ;; esac
  (cd -P -- "$common" && pwd -P)
}

lease_path() {
  local repository=$1 feature_key=$2 common checksum bytes
  common=$(common_directory "$repository") || return 1
  set -- $(printf '%s' "$feature_key" | cksum)
  checksum=$1
  bytes=$2
  printf '%s/superteam-integration-leases/%s-%s.lock\n' "$common" "$checksum" "$bytes"
}

cleanup_pending_lease() {
  if [ -n "$LEASE_PENDING" ]; then
    rm -f -- "$LEASE_PENDING/heartbeat" 2>/dev/null || true
    rm -f -- "$LEASE_PENDING/owner" 2>/dev/null || true
    rmdir -- "$LEASE_PENDING" 2>/dev/null || true
  fi
}

cleanup_pending_lease_guard() {
  if [ -n "$LEASE_GUARD_PENDING" ]; then
    rmdir -- "$LEASE_GUARD_PENDING" 2>/dev/null || true
  fi
}

cleanup_pending_heartbeat() {
  if [ -n "$LEASE_HEARTBEAT_PENDING" ]; then
    rm -f -- "$LEASE_HEARTBEAT_PENDING" 2>/dev/null || true
  fi
}

cleanup_lease_state() {
  cleanup_pending_heartbeat
  cleanup_pending_lease
  cleanup_pending_lease_guard
}

interrupt_lease_state() {
  cleanup_lease_state
  exit 130
}

lease_guard_acquire() {
  local lease=$1 guard
  guard=$lease.guard
  if ! mkdir -- "$guard" 2>/dev/null; then
    fail 'integration lease transition is already in progress.'
    return 3
  fi
  LEASE_GUARD_PENDING=$guard
}

lease_guard_release() {
  rmdir -- "$LEASE_GUARD_PENDING" || return 1
  LEASE_GUARD_PENDING=''
}

current_epoch() {
  date +%s
}

validate_nonnegative_integer() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9]+$'
}

write_lease_heartbeat() {
  local lease=$1 epoch=$2
  LEASE_HEARTBEAT_PENDING=$(mktemp "$lease/.heartbeat.XXXXXX") || return 1
  printf '%s\n' "$epoch" > "$LEASE_HEARTBEAT_PENDING" || return 1
  mv -- "$LEASE_HEARTBEAT_PENDING" "$lease/heartbeat" || return 1
  LEASE_HEARTBEAT_PENDING=''
}

trap cleanup_lease_state EXIT
trap interrupt_lease_state HUP INT TERM

command=${1:-}
[ -n "$command" ] || usage
shift

case "$command" in
  prepare)
    [ "$#" -eq 5 ] || usage
    repository=$(repository_root "$1") || exit 1
    feature_branch=$2
    ticket_branch=$3
    integration_branch=$4
    requested_path=$5
    for branch in "$feature_branch" "$ticket_branch" "$integration_branch"; do
      validate_branch "$branch" || exit 2
    done
    [ "$feature_branch" != "$ticket_branch" ] &&
      [ "$feature_branch" != "$integration_branch" ] &&
      [ "$ticket_branch" != "$integration_branch" ] || {
        fail 'feature, ticket, and integration branches must differ.'
        exit 2
      }
    for branch in "$feature_branch" "$ticket_branch"; do
      isolated_git -C "$repository" show-ref --verify --quiet "refs/heads/$branch" || {
        fail "branch not found: $branch"
        exit 1
      }
    done
    ticket_worktree=$(branch_worktree "$repository" "$ticket_branch")
    if [ -n "$ticket_worktree" ]; then
      if ! ticket_worktree_state=$(git_worktree_state "$ticket_worktree"); then
        fail "could not inspect ticket worktree: $ticket_worktree"
        exit 1
      fi
      if [ "$ticket_worktree_state" = DIRTY ]; then
        fail "ticket worktree is dirty: $ticket_worktree"
        exit 3
      fi
    fi
    base=$(isolated_git -C "$repository" rev-parse "refs/heads/$feature_branch^{commit}")
    path=$(absolute_worktree_path "$requested_path") || exit 1
    occupied=$(branch_worktree "$repository" "$integration_branch")
    if [ -n "$occupied" ]; then
      same_path "$occupied" "$path" || {
        fail "integration branch is checked out elsewhere: $occupied"
        exit 3
      }
    elif isolated_git -C "$repository" show-ref --verify --quiet "refs/heads/$integration_branch"; then
      isolated_git -C "$repository" worktree add -q "$path" "$integration_branch"
    else
      isolated_git -C "$repository" worktree add -q -b "$integration_branch" "$path" "$feature_branch"
    fi
    if ! integration_worktree_state=$(git_worktree_state "$path"); then
      fail "could not inspect integration worktree: $path"
      exit 1
    fi
    [ "$integration_worktree_state" = CLEAN ] || {
      fail "integration worktree is dirty: $path"
      exit 3
    }
    current=$(isolated_git -C "$path" rev-parse 'HEAD^{commit}')
    if isolated_git -C "$path" merge-base --is-ancestor "refs/heads/$ticket_branch" HEAD; then
      if isolated_git -C "$path" merge-base --is-ancestor "$base" HEAD; then
        action=already-prepared
      else
        if ! isolated_git -C "$path" merge --no-edit "$feature_branch"; then
          printf '%s\n' \
            "ERROR: refresh conflict requires a fresh superteam-resolving-merge-conflicts agent: $path" >&2
          exit 4
        fi
        action=refreshed
      fi
    else
      [ "$current" = "$base" ] || {
        fail "integration branch does not start at current feature head: expected=$base actual=$current"
        exit 3
      }
      if ! isolated_git -C "$path" merge --no-edit "$ticket_branch"; then
        printf '%s\n' \
          "ERROR: merge conflict requires a fresh superteam-resolving-merge-conflicts agent: $path" >&2
        exit 4
      fi
      action=prepared
    fi
    prepared_head=$(isolated_git -C "$path" rev-parse HEAD)
    printf 'repository=%s base=%s prepared=%s branch=%s path=%s action=%s\n' \
      "$repository" "$base" "$prepared_head" "$integration_branch" \
      "$path" "$action"
    ;;
  promote)
    [ "$#" -eq 4 ] || usage
    repository=$(repository_root "$1") || exit 1
    feature_branch=$2
    integration_branch=$3
    expected=$4
    validate_branch "$feature_branch" || exit 2
    validate_branch "$integration_branch" || exit 2
    expected=$(isolated_git -C "$repository" rev-parse --verify "$expected^{commit}" 2>/dev/null) || {
      fail 'expected feature head is not a commit.'
      exit 1
    }
    for branch in "$feature_branch" "$integration_branch"; do
      isolated_git -C "$repository" show-ref --verify --quiet "refs/heads/$branch" || {
        fail "branch not found: $branch"
        exit 1
      }
    done
    feature_worktree=$(branch_worktree "$repository" "$feature_branch")
    [ -z "$feature_worktree" ] || {
      fail 'canonical feature branch is checked out and cannot be promoted.'
      exit 3
    }
    actual=$(isolated_git -C "$repository" rev-parse "refs/heads/$feature_branch")
    [ "$actual" = "$expected" ] || {
      fail "feature head changed: expected=$expected actual=$actual"
      exit 3
    }
    prepared=$(isolated_git -C "$repository" rev-parse "refs/heads/$integration_branch")
    isolated_git -C "$repository" merge-base --is-ancestor "$expected" "$prepared" || {
      fail 'prepared integration is not a fast-forward of the feature head.'
      exit 3
    }
    if ! isolated_git -C "$repository" update-ref "refs/heads/$feature_branch" "$prepared" "$expected"; then
      actual=$(isolated_git -C "$repository" rev-parse "refs/heads/$feature_branch")
      fail "feature head changed during promotion: expected=$expected actual=$actual"
      exit 3
    fi
    printf 'repository=%s previous=%s integrated=%s branch=%s\n' \
      "$repository" "$expected" "$prepared" "$feature_branch"
    ;;
  lease-acquire|lease-heartbeat|lease-release)
    [ "$#" -eq 4 ] && [ "$3" = --owner ] || usage
    repository=$(repository_root "$1") || exit 1
    feature_key=$2
    owner=$4
    [ -n "$feature_key" ] && [ -n "$owner" ] || usage
    reject_control_value "$feature_key" 'feature key' || exit 2
    reject_control_value "$owner" owner || exit 2
    lease=$(lease_path "$repository" "$feature_key") || exit 1
    if [ "$command" = lease-acquire ]; then
      lease_parent=$(dirname -- "$lease")
      mkdir -p -- "$lease_parent"
      if ! mkdir -- "$lease" 2>/dev/null; then
        held_by=$(sed -n '1p' "$lease/owner" 2>/dev/null || printf '%s' unknown)
        fail "integration lease is held: owner=$held_by"
        exit 3
      fi
      LEASE_PENDING=$lease
      if ! printf '%s\n' "$owner" > "$lease/owner"; then
        cleanup_pending_lease
        exit 1
      fi
      if ! write_lease_heartbeat "$lease" "$(current_epoch)"; then
        cleanup_pending_lease
        exit 1
      fi
      LEASE_PENDING=''
      printf 'lease=%s owner=%s action=acquired\n' "$lease" "$owner"
    elif [ "$command" = lease-heartbeat ]; then
      lease_guard_acquire "$lease" || exit $?
      [ -f "$lease/owner" ] && [ -f "$lease/heartbeat" ] || {
        fail 'integration lease is missing or incomplete.'
        exit 3
      }
      held_by=$(sed -n '1p' "$lease/owner")
      [ "$held_by" = "$owner" ] || {
        fail "integration lease is owned by $held_by"
        exit 3
      }
      write_lease_heartbeat "$lease" "$(current_epoch)"
      lease_guard_release
      printf 'lease=%s owner=%s action=heartbeat\n' "$lease" "$owner"
    else
      lease_guard_acquire "$lease" || exit $?
      [ -f "$lease/owner" ] || {
        lease_guard_release
        printf 'lease=%s owner=%s action=absent\n' "$lease" "$owner"
        exit 0
      }
      held_by=$(sed -n '1p' "$lease/owner")
      [ "$held_by" = "$owner" ] || {
        fail "integration lease is owned by $held_by"
        exit 3
      }
      rm -f -- "$lease/heartbeat"
      rm -f -- "$lease/owner"
      rmdir -- "$lease"
      lease_guard_release
      printf 'lease=%s owner=%s action=released\n' "$lease" "$owner"
    fi
    ;;
  lease-recover)
    [ "$#" -eq 8 ] && [ "$3" = --owner ] &&
      [ "$5" = --expected-owner ] && [ "$7" = --stale-after ] || usage
    repository=$(repository_root "$1") || exit 1
    feature_key=$2
    owner=$4
    expected_owner=$6
    stale_after=$8
    [ -n "$feature_key" ] && [ -n "$owner" ] && [ -n "$expected_owner" ] || usage
    reject_control_value "$feature_key" 'feature key' || exit 2
    reject_control_value "$owner" owner || exit 2
    reject_control_value "$expected_owner" 'expected owner' || exit 2
    validate_nonnegative_integer "$stale_after" || {
      fail 'stale-after must be a nonnegative integer.'
      exit 2
    }
    [ "$stale_after" -ge 300 ] || {
      fail 'stale-after must be at least 300 seconds.'
      exit 2
    }
    lease=$(lease_path "$repository" "$feature_key") || exit 1
    lease_guard_acquire "$lease" || exit $?
    [ -f "$lease/owner" ] && [ -f "$lease/heartbeat" ] || {
      fail 'integration lease is missing or incomplete.'
      exit 3
    }
    held_by=$(sed -n '1p' "$lease/owner")
    [ "$held_by" = "$expected_owner" ] || {
      fail "integration lease owner changed: expected=$expected_owner actual=$held_by"
      exit 3
    }
    heartbeat=$(sed -n '1p' "$lease/heartbeat")
    validate_nonnegative_integer "$heartbeat" || {
      fail 'integration lease heartbeat is invalid.'
      exit 3
    }
    now=$(current_epoch)
    validate_nonnegative_integer "$now" || exit 1
    [ "$now" -ge "$heartbeat" ] || {
      fail 'integration lease heartbeat is in the future.'
      exit 3
    }
    age=$((now - heartbeat))
    [ "$age" -ge "$stale_after" ] || {
      fail "integration lease is active: owner=$held_by age=$age"
      exit 3
    }
    rm -f -- "$lease/heartbeat" "$lease/owner"
    rmdir -- "$lease"
    mkdir -- "$lease"
    LEASE_PENDING=$lease
    printf '%s\n' "$owner" > "$lease/owner"
    write_lease_heartbeat "$lease" "$now"
    LEASE_PENDING=''
    lease_guard_release
    printf 'lease=%s owner=%s previous_owner=%s action=recovered\n' \
      "$lease" "$owner" "$held_by"
    ;;
  *) usage ;;
esac
