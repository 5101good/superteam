#!/usr/bin/env bash
set -euo pipefail

CALLER_DIRECTORY=$(pwd -P)
SCRIPT_DIRECTORY=$(cd "$(dirname "$0")" && pwd -P)
. "$SCRIPT_DIRECTORY/lib/git.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  st-worktree.sh stable-path <repository-root> <feature> <ticket> <repository-id> <role>
  st-worktree.sh prepare-feature <repository-root> <feature-branch>
  st-worktree.sh add-ticket <repository-root> <feature-branch> <ticket-branch> <worktree-path>
  st-worktree.sh remove <repository-root> <worktree-path> [--delete-branch <branch>]

Creates and removes local Git worktrees. It never fetches, pushes, creates a
remote, or changes a remote item.
EOF
  exit 2
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
}

reject_line_breaks() {
  case "$1" in
    *$'\n'*|*$'\r'*) fail "$2 contains an unsupported line break."; return 1 ;;
  esac
}

repository_root() {
  local candidate=$1 resolved top
  reject_line_breaks "$candidate" 'repository path' || return 1
  [ -d "$candidate" ] || { fail "repository not found: $candidate"; return 1; }
  resolved=$(cd -P -- "$candidate" && pwd -P) || return 1
  top=$(isolated_git -C "$resolved" rev-parse --show-toplevel 2>/dev/null) || {
    fail "not a Git worktree: $resolved"
    return 1
  }
  top=$(cd -P -- "$top" && pwd -P) || return 1
  [ "$resolved" = "$top" ] || {
    fail "path is not the Repository root: $resolved"
    return 1
  }
  printf '%s\n' "$resolved"
}

validate_branch() {
  reject_line_breaks "$1" 'branch name' || return 1
  isolated_git check-ref-format --branch "$1" >/dev/null 2>&1 || {
    fail "invalid branch: $1"
    return 1
  }
}

validate_feature_branch() {
  validate_branch "$1" || return 1
  case "$1" in
    main|master)
      fail "protected branch cannot be used as a Superteam feature branch: $1"
      return 1
      ;;
  esac
}

absolute_worktree_path() {
  local input=$1 candidate parent leaf
  reject_line_breaks "$input" 'worktree path' || return 1
  case "$input" in
    /*) candidate=$input ;;
    *) candidate=$CALLER_DIRECTORY/$input ;;
  esac
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

rollback_added_worktree() {
  local repository=$1 path=$2 branch=$3 delete_branch=$4 occupied failed=0
  occupied=$(branch_worktree "$repository" "$branch")
  if [ -n "$occupied" ] && same_path "$occupied" "$path"; then
    isolated_git -C "$repository" worktree remove --force "$path" >/dev/null 2>&1 || failed=1
  fi
  if [ "$delete_branch" -eq 1 ] &&
     isolated_git -C "$repository" show-ref --verify --quiet "refs/heads/$branch"; then
    isolated_git -C "$repository" branch -D "$branch" >/dev/null 2>&1 || failed=1
  fi
  [ "$failed" -eq 0 ]
}

command=${1:-}
[ -n "$command" ] || usage
shift

case "$command" in
  stable-path)
    [ "$#" -eq 5 ] || usage
    repository=$(repository_root "$1") || exit 1
    feature=$2
    ticket=$3
    repository_id=$4
    role=$5
    reject_line_breaks "$feature" 'feature key' || exit 2
    reject_line_breaks "$ticket" 'ticket ID' || exit 2
    reject_line_breaks "$repository_id" 'Repository ID' || exit 2
    printf '%s\n' "$feature" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || {
      fail 'invalid feature key.'
      exit 2
    }
    printf '%s\n' "$ticket" | LC_ALL=C grep -Eq '^[0-9][0-9]$' || {
      fail 'invalid ticket ID.'
      exit 2
    }
    printf '%s\n' "$repository_id" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9._-]*$' || {
      fail 'invalid Repository ID.'
      exit 2
    }
    case "$role" in
      ticket|integration|tracking-claim|tracking-claim-integration|tracking-result|tracking-result-integration) ;;
      *) fail 'invalid worktree role.'; exit 2 ;;
    esac
    stable_root=${SUPERTEAM_WORKTREE_ROOT:-${TMPDIR:-/tmp}/superteam-worktrees}
    reject_line_breaks "$stable_root" 'stable worktree root' || exit 2
    case "$stable_root" in /*) ;; *) fail 'stable worktree root must be absolute.'; exit 2 ;; esac
    while [ "$stable_root" != / ] && [ "${stable_root%/}" != "$stable_root" ]; do
      stable_root=${stable_root%/}
    done
    set -- $(printf '%s' "$repository" | cksum)
    project_key=$1-$2
    printf '%s/%s/%s/%s/%s/%s\n' "$stable_root" "$project_key" "$feature" \
      "$ticket" "$repository_id" "$role"
    ;;
  prepare-feature)
    [ "$#" -eq 2 ] || usage
    repository=$(repository_root "$1") || exit 1
    feature_branch=$2
    validate_feature_branch "$feature_branch" || exit 2
    if ! worktree_state=$(git_worktree_state "$repository"); then
      fail "could not inspect Repository worktree: $repository"
      exit 1
    fi
    [ "$worktree_state" = CLEAN ] || {
      fail "Repository baseline is dirty: $repository"
      exit 3
    }
    occupied=$(branch_worktree "$repository" "$feature_branch")
    [ -z "$occupied" ] || {
      fail "canonical feature branch is checked out: $occupied"
      exit 3
    }
    base=$(isolated_git -C "$repository" rev-parse 'HEAD^{commit}')
    if isolated_git -C "$repository" show-ref --verify --quiet "refs/heads/$feature_branch"; then
      action=existing
    else
      isolated_git -C "$repository" branch "$feature_branch" "$base"
      action=created
    fi
    feature_head=$(isolated_git -C "$repository" rev-parse "refs/heads/$feature_branch")
    printf 'repository=%s base=%s head=%s branch=%s action=%s\n' \
      "$repository" "$base" "$feature_head" \
      "$feature_branch" "$action"
    ;;
  add-ticket)
    [ "$#" -eq 4 ] || usage
    repository=$(repository_root "$1") || exit 1
    feature_branch=$2
    ticket_branch=$3
    requested_path=$4
    validate_feature_branch "$feature_branch" || exit 2
    validate_branch "$ticket_branch" || exit 2
    [ "$ticket_branch" != "$feature_branch" ] || { fail 'ticket and feature branches must differ.'; exit 2; }
    isolated_git -C "$repository" show-ref --verify --quiet "refs/heads/$feature_branch" || {
      fail "feature branch not found: $feature_branch"
      exit 1
    }
    path=$(absolute_worktree_path "$requested_path") || exit 1
    occupied=$(branch_worktree "$repository" "$ticket_branch")
    if [ -n "$occupied" ]; then
      same_path "$occupied" "$path" || {
        fail "ticket branch is checked out elsewhere: $occupied"
        exit 3
      }
      action=existing
      added=0
      delete_branch=0
    else
      added=1
      if isolated_git -C "$repository" show-ref --verify --quiet "refs/heads/$ticket_branch"; then
        delete_branch=0
        if ! isolated_git -C "$repository" worktree add -q "$path" "$ticket_branch"; then
          fail "failed to create ticket worktree: $path"
          exit 1
        fi
        action=resumed
      else
        delete_branch=1
        if ! isolated_git -C "$repository" worktree add -q -b "$ticket_branch" "$path" "$feature_branch"; then
          rollback_added_worktree "$repository" "$path" "$ticket_branch" "$delete_branch" || true
          fail "failed to create ticket worktree: $path"
          exit 1
        fi
        action=created
      fi
    fi

    verification_failed=0
    actual_branch=''
    head=''
    registered=''
    [ -d "$path" ] || verification_failed=1
    if [ "$verification_failed" -eq 0 ]; then
      actual_branch=$(isolated_git -C "$path" symbolic-ref --short HEAD 2>/dev/null) || verification_failed=1
    fi
    if [ "$verification_failed" -eq 0 ]; then
      head=$(isolated_git -C "$path" rev-parse HEAD 2>/dev/null) || verification_failed=1
    fi
    if [ "$verification_failed" -eq 0 ]; then
      registered=$(branch_worktree "$repository" "$ticket_branch")
      [ -n "$registered" ] && same_path "$registered" "$path" &&
        [ "$actual_branch" = "$ticket_branch" ] || verification_failed=1
    fi
    if [ "$verification_failed" -ne 0 ]; then
      if [ "$added" -eq 1 ]; then
        rollback_added_worktree "$repository" "$path" "$ticket_branch" "$delete_branch" ||
          fail "failed to roll back ticket worktree: path=$path branch=$ticket_branch"
      fi
      fail "failed to verify ticket worktree: $path"
      exit 1
    fi
    printf 'repository=%s path=%s branch=%s action=%s head=%s\n' \
      "$repository" "$path" "$ticket_branch" "$action" "$head"
    ;;
  remove)
    [ "$#" -ge 2 ] || usage
    repository=$(repository_root "$1") || exit 1
    requested_path=$2
    shift 2
    delete_branch=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --delete-branch) delete_branch=${2:-}; [ -n "$delete_branch" ] || usage; shift 2 ;;
        *) usage ;;
      esac
    done
    path=$(absolute_worktree_path "$requested_path") || exit 1
    if [ -n "$delete_branch" ]; then validate_branch "$delete_branch" || exit 2; fi
    if [ -e "$path" ]; then
      if ! worktree_state=$(git_worktree_state "$path"); then
        fail "could not inspect worktree before removal: $path"
        exit 1
      fi
      [ "$worktree_state" = CLEAN ] || {
        fail "worktree is dirty and will be preserved: $path"
        exit 3
      }
      isolated_git -C "$repository" worktree remove "$path"
    else
      isolated_git -C "$repository" worktree prune
    fi
    if [ -n "$delete_branch" ]; then isolated_git -C "$repository" branch -d "$delete_branch"; fi
    printf 'repository=%s path=%s action=removed\n' "$repository" "$path"
    ;;
  *) usage ;;
esac
