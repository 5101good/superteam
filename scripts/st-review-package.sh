#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY=$(cd "$(dirname "$0")" && pwd -P)
. "$SCRIPT_DIRECTORY/lib/git.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  st-review-package.sh <fixed-base> [WORKTREE|<head>]

Prints a read-only review package for a fixed Git range. WORKTREE includes
committed, staged, unstaged, and untracked changes. Requires only Git and Bash.
EOF
  exit 2
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
fixed_base=$1
review_head=${2:-WORKTREE}

export LC_ALL=C

review_git() {
  isolated_git --no-optional-locks "$@"
}

repository_root=$(review_git rev-parse --show-toplevel 2>/dev/null) || {
  fail 'current directory is not inside a Git worktree.'
  exit 1
}
cd "$repository_root"

base_commit=$(review_git rev-parse --verify "$fixed_base^{commit}" 2>/dev/null) || {
  fail 'fixed base is not a commit.'
  exit 1
}

mode=COMMIT
if [ "$review_head" = WORKTREE ]; then
  mode=WORKTREE
  head_commit=$(review_git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
    fail 'current HEAD is not a commit.'
    exit 1
  }
else
  head_commit=$(review_git rev-parse --verify "$review_head^{commit}" 2>/dev/null) || {
    fail 'review head is not a commit.'
    exit 1
  }
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/superteam-review.XXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
untracked_list="$scratch/untracked"
: > "$untracked_list"

if [ "$mode" = WORKTREE ]; then
  review_git ls-files --others --exclude-standard -z > "$untracked_list"
  if review_git diff --quiet "$base_commit" -- && [ ! -s "$untracked_list" ]; then
    fail 'effective change is empty.'
    exit 3
  fi
elif review_git diff --quiet "$base_commit" "$head_commit" --; then
  fail 'effective change is empty.'
  exit 3
fi

emit_untracked_names() {
  local path
  while IFS= read -r -d '' path; do
    printf 'UNTRACKED: %s\n' "$path"
  done < "$untracked_list"
}

emit_untracked_diffs() {
  local path status
  while IFS= read -r -d '' path; do
    status=0
    review_git diff --no-index --binary --no-ext-diff -- /dev/null "./$path" || status=$?
    [ "$status" -eq 1 ] || return "$status"
  done < "$untracked_list"
}

printf '%s\n' '=== REVIEW RANGE ==='
printf 'BASE: %s\n' "$base_commit"
printf 'HEAD: %s\n' "$head_commit"
printf 'MODE: %s\n' "$mode"
printf '\n%s\n' '=== COMMITS ==='
review_git log --oneline "$base_commit..$head_commit"
printf '\n%s\n' '=== SUMMARY ==='
if [ "$mode" = WORKTREE ]; then
  review_git diff --stat --no-ext-diff "$base_commit" --
  emit_untracked_names
else
  review_git diff --stat --no-ext-diff "$base_commit" "$head_commit" --
fi
printf '\n%s\n' '=== DIFF ==='
if [ "$mode" = WORKTREE ]; then
  review_git diff --binary --no-ext-diff --no-textconv -U5 "$base_commit" --
  emit_untracked_diffs
else
  review_git diff --binary --no-ext-diff --no-textconv -U5 "$base_commit" "$head_commit" --
fi
