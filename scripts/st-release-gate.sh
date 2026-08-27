#!/usr/bin/env bash

set -u

SCRIPT_DIRECTORY=$(cd "$(dirname "$0")" && pwd -P)
. "$SCRIPT_DIRECTORY/lib/git.sh"

LC_ALL=C
export LC_ALL

list_checks() {
  printf '%s\n' \
    git-diff-check \
    shell-bash-n \
    full-bats \
    release-audit \
    host-discovery
}

fail() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

if [ "${1:-}" = --list-checks ]; then
  [ "$#" -eq 1 ] || fail 'usage: st-release-gate.sh --list-checks'
  list_checks
  exit 0
fi

release_root=${1:-}
[ "$#" -eq 1 ] && [ -n "$release_root" ] || \
  fail 'usage: st-release-gate.sh <release-root>'
[ -d "$release_root" ] || fail 'release root does not exist'
release_root=$(cd -P -- "$release_root" 2>/dev/null && pwd -P) || \
  fail 'release root cannot be resolved'
isolated_git -C "$release_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  fail 'release root must be a Git worktree'

candidate_head=$(isolated_git -C "$release_root" rev-parse HEAD) || \
  fail 'candidate HEAD cannot be resolved'
candidate_tree=$(isolated_git -C "$release_root" rev-parse HEAD^{tree}) || \
  fail 'candidate tree cannot be resolved'
worktree_state=$(git_worktree_state "$release_root") || \
  fail 'candidate worktree state cannot be inspected'
[ "$worktree_state" = CLEAN ] || fail 'release gate requires a clean candidate worktree'

printf '%s\n' 'CHECK: git-diff-check'
isolated_git -C "$release_root" diff --check || fail 'git diff --check failed'

printf '%s\n' 'CHECK: shell-bash-n'
while IFS= read -r -d '' script_file; do
  [ -n "$script_file" ] || continue
  bash -n "$release_root/$script_file" || fail "shell syntax failed: $script_file"
done < <(isolated_git -C "$release_root" ls-files -z -- '*.sh')

printf '%s\n' 'CHECK: full-bats'
(cd "$release_root" && bats tests) || fail 'full Bats suite failed'

printf '%s\n' 'CHECK: release-audit'
bash "$release_root/scripts/st-release-audit.sh" "$release_root" || \
  fail 'release audit failed'

printf '%s\n' 'CHECK: host-discovery'
bash "$release_root/scripts/st-host-discovery.sh" "$release_root" || \
  fail 'Host discovery failed'

platform_name=$(uname -s 2>/dev/null || printf '%s\n' unknown)
platform_release=$(uname -r 2>/dev/null || printf '%s\n' unknown)
platform_machine=$(uname -m 2>/dev/null || printf '%s\n' unknown)
git_version=$(git --version 2>&1 | sed -n '1p')
bash_version=$(bash --version 2>&1 | sed -n '1p')
bats_version=$(bats --version 2>&1 | sed -n '1p')

printf '%s\n' \
  "CANDIDATE_HEAD: $candidate_head" \
  "CANDIDATE_TREE: $candidate_tree" \
  "PLATFORM: $platform_name $platform_release $platform_machine" \
  "GIT_VERSION: $git_version" \
  "BASH_VERSION: $bash_version" \
  "BATS_VERSION: $bats_version" \
  'REMOTE_CI: NOT RUN BY THIS LOCAL GATE' \
  'RELEASE_GATE_RESULT: PASS'
