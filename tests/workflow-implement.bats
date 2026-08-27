#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
WORKTREE="$ROOT/scripts/st-worktree.sh"
INTEGRATE="$ROOT/scripts/st-integrate.sh"

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/root project"
  mkdir -p "$FIXTURE_ROOT" "$BATS_TEST_TMPDIR/no-hooks"
  git -C "$FIXTURE_ROOT" init -q
  git -C "$FIXTURE_ROOT" config user.name "Fixture Contributor"
  git -C "$FIXTURE_ROOT" config user.email "fixture@invalid"
  git -C "$FIXTURE_ROOT" config core.hooksPath "$BATS_TEST_TMPDIR/no-hooks"
  printf '%s\n' base > "$FIXTURE_ROOT/tracked.txt"
  git -C "$FIXTURE_ROOT" add tracked.txt
  git -C "$FIXTURE_ROOT" commit -qm baseline
  git -C "$FIXTURE_ROOT" branch -M main
}

prepare_ticket_change() {
  bash "$WORKTREE" prepare-feature "$FIXTURE_ROOT" superteam/100-example >/dev/null
  FEATURE_BASE=$(git -C "$FIXTURE_ROOT" rev-parse refs/heads/superteam/100-example)
  TICKET_WORKTREE="$BATS_TEST_TMPDIR/ticket worktree"
  bash "$WORKTREE" add-ticket "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-ticket-01-root "$TICKET_WORKTREE" >/dev/null
  printf '%s\n' ticket > "$TICKET_WORKTREE/ticket.txt"
  git -C "$TICKET_WORKTREE" add ticket.txt
  git -C "$TICKET_WORKTREE" commit -qm 'feat: deliver ticket'
}

@test "a root ticket gets an isolated branch and worktree from the feature head" {
  bash "$WORKTREE" prepare-feature "$FIXTURE_ROOT" superteam/100-example >/dev/null
  feature_head=$(git -C "$FIXTURE_ROOT" rev-parse refs/heads/superteam/100-example)

  run bash -c 'cd "$1" && bash "$2" add-ticket "$3" superteam/100-example superteam/100-example-ticket-01-root "relative worktrees/ticket 01"' \
    _ "$BATS_TEST_TMPDIR" "$WORKTREE" "$FIXTURE_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"repository=$FIXTURE_ROOT"* ]]
  [[ "$output" == *"branch=superteam/100-example-ticket-01-root"* ]]
  expected_path=$(cd -P "$BATS_TEST_TMPDIR/relative worktrees" && pwd -P)/ticket\ 01
  [[ "$output" == *"path=$expected_path"* ]]
  [ "$(git -C "$BATS_TEST_TMPDIR/relative worktrees/ticket 01" rev-parse HEAD)" = "$feature_head" ]
  [ "$(git -C "$BATS_TEST_TMPDIR/relative worktrees/ticket 01" symbolic-ref --short HEAD)" = \
    superteam/100-example-ticket-01-root ]
}

@test "stable worktree paths are derived from Project ticket Repository and role" {
  stable_root="$BATS_TEST_TMPDIR/stable worktrees"

  run env SUPERTEAM_WORKTREE_ROOT="$stable_root" bash "$WORKTREE" stable-path \
    "$FIXTURE_ROOT" 100-example 01 root ticket
  [ "$status" -eq 0 ]
  first=$output
  [[ "$first" == "$stable_root"/*/100-example/01/root/ticket ]]

  run env SUPERTEAM_WORKTREE_ROOT="$stable_root" bash "$WORKTREE" stable-path \
    "$FIXTURE_ROOT" 100-example 01 root ticket
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]

  run env SUPERTEAM_WORKTREE_ROOT="$stable_root" bash "$WORKTREE" stable-path \
    "$FIXTURE_ROOT" 100-example 01 root integration
  [ "$status" -eq 0 ]
  [ "$output" != "$first" ]
  [[ "$output" == */100-example/01/root/integration ]]
  [ ! -e "$stable_root" ]
}

@test "a failed ticket worktree postcondition rolls back the owned branch and path" {
  bash "$WORKTREE" prepare-feature "$FIXTURE_ROOT" superteam/100-example >/dev/null
  fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir "$fake_bin"
  real_git=$(command -v git)
  cat > "$fake_bin/git" <<EOF
#!/usr/bin/env bash
arguments=("\$@")
while [ "\$#" -gt 0 ]; do
  if [ "\${1:-}" = -C ] && [ "\${2:-}" = "\${FAIL_WORKTREE:-}" ] &&
     [ "\${3:-}" = rev-parse ] && [ "\${4:-}" = HEAD ]; then
    exit 91
  fi
  shift
done
exec "$real_git" "\${arguments[@]}"
EOF
  chmod +x "$fake_bin/git"

  resolved_broken=$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)/broken\ ticket
  run env PATH="$fake_bin:$PATH" FAIL_WORKTREE="$resolved_broken" \
    bash "$WORKTREE" add-ticket "$FIXTURE_ROOT" superteam/100-example \
      superteam/100-example-ticket-01-root "$BATS_TEST_TMPDIR/broken ticket"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to verify ticket worktree"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/broken ticket" ]
  ! git -C "$FIXTURE_ROOT" show-ref --verify --quiet \
    refs/heads/superteam/100-example-ticket-01-root
}

@test "prepare and promote integrate a reviewed ticket with auditable heads" {
  prepare_ticket_change
  integration_worktree="$BATS_TEST_TMPDIR/integration worktree"

  run bash "$INTEGRATE" prepare "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-ticket-01-root superteam/100-example-integrate-01-root \
    "$integration_worktree"
  [ "$status" -eq 0 ]
  [[ "$output" == *"base=$FEATURE_BASE"* ]]
  [[ "$output" == *"prepared="* ]]
  prepared=$(git -C "$FIXTURE_ROOT" rev-parse refs/heads/superteam/100-example-integrate-01-root)

  run bash "$INTEGRATE" promote "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-integrate-01-root "$FEATURE_BASE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"previous=$FEATURE_BASE"* ]]
  [[ "$output" == *"integrated=$prepared"* ]]
  [ "$(git -C "$FIXTURE_ROOT" rev-parse refs/heads/superteam/100-example)" = "$prepared" ]
  git -C "$FIXTURE_ROOT" merge-base --is-ancestor \
    refs/heads/superteam/100-example-ticket-01-root refs/heads/superteam/100-example
  [ -z "$(git -C "$FIXTURE_ROOT" remote)" ]
}

@test "promotion CAS failure preserves a concurrent feature update" {
  prepare_ticket_change
  integration_worktree="$BATS_TEST_TMPDIR/integration worktree"
  bash "$INTEGRATE" prepare "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-ticket-01-root superteam/100-example-integrate-01-root \
    "$integration_worktree" >/dev/null

  tree=$(git -C "$FIXTURE_ROOT" rev-parse "$FEATURE_BASE^{tree}")
  concurrent=$(printf '%s\n' concurrent | git -C "$FIXTURE_ROOT" commit-tree "$tree" -p "$FEATURE_BASE")
  git -C "$FIXTURE_ROOT" update-ref refs/heads/superteam/100-example "$concurrent" "$FEATURE_BASE"

  run bash "$INTEGRATE" promote "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-integrate-01-root "$FEATURE_BASE"

  [ "$status" -eq 3 ]
  [[ "$output" == *"feature head changed"* ]]
  [ "$(git -C "$FIXTURE_ROOT" rev-parse refs/heads/superteam/100-example)" = "$concurrent" ]

  run bash "$INTEGRATE" prepare "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-ticket-01-root superteam/100-example-integrate-01-root \
    "$integration_worktree"
  [ "$status" -eq 0 ]
  [[ "$output" == *"base=$concurrent"* ]]
  [[ "$output" == *"action=refreshed"* ]]

  run bash "$INTEGRATE" promote "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-integrate-01-root "$concurrent"
  [ "$status" -eq 0 ]
  git -C "$FIXTURE_ROOT" merge-base --is-ancestor "$concurrent" \
    refs/heads/superteam/100-example
  git -C "$FIXTURE_ROOT" merge-base --is-ancestor \
    refs/heads/superteam/100-example-ticket-01-root refs/heads/superteam/100-example
}

@test "prepare leaves a real conflict active for the independent conflict workflow" {
  prepare_ticket_change
  printf '%s\n' ticket > "$TICKET_WORKTREE/tracked.txt"
  git -C "$TICKET_WORKTREE" add tracked.txt
  git -C "$TICKET_WORKTREE" commit -qm 'feat: change ticket side'

  feature_worktree="$BATS_TEST_TMPDIR/feature worktree"
  git -C "$FIXTURE_ROOT" worktree add -q "$feature_worktree" superteam/100-example
  printf '%s\n' feature > "$feature_worktree/tracked.txt"
  git -C "$feature_worktree" add tracked.txt
  git -C "$feature_worktree" commit -qm 'feat: change feature side'
  git -C "$FIXTURE_ROOT" worktree remove "$feature_worktree"

  integration_worktree="$BATS_TEST_TMPDIR/conflicted integration"
  run bash "$INTEGRATE" prepare "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-ticket-01-root superteam/100-example-integrate-01-root \
    "$integration_worktree"

  [ "$status" -eq 4 ]
  [[ "$output" == *"superteam-resolving-merge-conflicts"* ]]
  [ -f "$integration_worktree/.git" ]
  git -C "$integration_worktree" rev-parse -q --verify MERGE_HEAD
  [ -n "$(git -C "$integration_worktree" diff --name-only --diff-filter=U)" ]
}

@test "standalone integration lease is exclusive and owner checked" {
  run bash "$INTEGRATE" lease-acquire "$FIXTURE_ROOT" 100-example --owner first
  [ "$status" -eq 0 ]
  [[ "$output" == *"owner=first"* ]]

  run bash "$INTEGRATE" lease-acquire "$FIXTURE_ROOT" 100-example --owner second
  [ "$status" -eq 3 ]
  [[ "$output" == *"integration lease is held"* ]]

  run bash "$INTEGRATE" lease-release "$FIXTURE_ROOT" 100-example --owner second
  [ "$status" -eq 3 ]
  [[ "$output" == *"integration lease is owned by first"* ]]

  bash "$INTEGRATE" lease-release "$FIXTURE_ROOT" 100-example --owner first >/dev/null
}

@test "claim and Result tracking commits are promoted into the canonical feature" {
  mkdir -p "$FIXTURE_ROOT/task/100-example/tickets"
  printf '%s\n' ready > "$FIXTURE_ROOT/task/100-example/tickets/01-root.md"
  git -C "$FIXTURE_ROOT" add task/100-example/tickets/01-root.md
  git -C "$FIXTURE_ROOT" commit -qm 'chore: add ready ticket'
  bash "$WORKTREE" prepare-feature "$FIXTURE_ROOT" superteam/100-example >/dev/null
  base=$(git -C "$FIXTURE_ROOT" rev-parse refs/heads/superteam/100-example)

  claim_path=$(env SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/tracking" \
    bash "$WORKTREE" stable-path "$FIXTURE_ROOT" 100-example 01 root tracking-claim)
  bash "$WORKTREE" add-ticket "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-track-01-claim "$claim_path" >/dev/null
  printf '%s\n' claimed > "$claim_path/task/100-example/tickets/01-root.md"
  git -C "$claim_path" add task/100-example/tickets/01-root.md
  git -C "$claim_path" commit -qm 'chore: claim ticket'
  bash "$INTEGRATE" promote "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-track-01-claim "$base" >/dev/null
  claim_head=$(git -C "$FIXTURE_ROOT" rev-parse refs/heads/superteam/100-example)

  ticket_path=$(env SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/tracking" \
    bash "$WORKTREE" stable-path "$FIXTURE_ROOT" 100-example 01 root ticket)
  bash "$WORKTREE" add-ticket "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-ticket-01-root "$ticket_path" >/dev/null
  printf '%s\n' delivered > "$ticket_path/delivered.txt"
  git -C "$ticket_path" add delivered.txt
  git -C "$ticket_path" commit -qm 'feat: deliver root ticket'
  integration_path=$(env SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/tracking" \
    bash "$WORKTREE" stable-path "$FIXTURE_ROOT" 100-example 01 root integration)
  bash "$INTEGRATE" prepare "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-ticket-01-root superteam/100-example-integrate-01-root \
    "$integration_path" >/dev/null
  bash "$INTEGRATE" promote "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-integrate-01-root "$claim_head" >/dev/null
  implementation_head=$(git -C "$FIXTURE_ROOT" rev-parse refs/heads/superteam/100-example)

  result_path=$(env SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/tracking" \
    bash "$WORKTREE" stable-path "$FIXTURE_ROOT" 100-example 01 root tracking-result)
  bash "$WORKTREE" add-ticket "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-track-01-result "$result_path" >/dev/null
  printf '%s\n' resolved > "$result_path/task/100-example/tickets/01-root.md"
  git -C "$result_path" add task/100-example/tickets/01-root.md
  git -C "$result_path" commit -qm 'chore: record ticket result'
  bash "$INTEGRATE" promote "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-track-01-result "$implementation_head" >/dev/null

  [ "$(git -C "$FIXTURE_ROOT" show superteam/100-example:task/100-example/tickets/01-root.md)" = \
    resolved ]
  git -C "$FIXTURE_ROOT" merge-base --is-ancestor "$claim_head" \
    refs/heads/superteam/100-example
  git -C "$FIXTURE_ROOT" merge-base --is-ancestor "$implementation_head" \
    refs/heads/superteam/100-example
}

@test "Git environment and hooks cannot redirect or extend local workflow effects" {
  bash "$WORKTREE" prepare-feature "$FIXTURE_ROOT" superteam/100-example >/dev/null
  outside="$BATS_TEST_TMPDIR/outside repository"
  hooks="$BATS_TEST_TMPDIR/injected hooks"
  sentinel="$BATS_TEST_TMPDIR/hook ran"
  mkdir -p "$outside" "$hooks"
  git -C "$outside" init -q
  for hook in post-checkout post-merge; do
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf 'printf ran > %q\n' "$sentinel"
    } > "$hooks/$hook"
    chmod +x "$hooks/$hook"
  done
  ticket_path="$BATS_TEST_TMPDIR/isolated ticket"
  environment=(
    GIT_DIR="$outside/.git"
    GIT_WORK_TREE="$outside"
    GIT_INDEX_FILE="$BATS_TEST_TMPDIR/foreign-index"
    GIT_CONFIG_COUNT=1
    GIT_CONFIG_KEY_0=core.hooksPath
    GIT_CONFIG_VALUE_0="$hooks"
  )

  run env "${environment[@]}" bash "$WORKTREE" add-ticket "$FIXTURE_ROOT" \
    superteam/100-example superteam/100-example-ticket-01-root "$ticket_path"
  [ "$status" -eq 0 ]
  [ ! -e "$sentinel" ]
  git -C "$FIXTURE_ROOT" show-ref --verify --quiet \
    refs/heads/superteam/100-example-ticket-01-root
  ! git -C "$outside" show-ref --verify --quiet \
    refs/heads/superteam/100-example-ticket-01-root

  printf '%s\n' isolated > "$ticket_path/isolated.txt"
  git -C "$ticket_path" add isolated.txt
  git -C "$ticket_path" commit -qm 'feat: isolated change'
  run env "${environment[@]}" bash "$INTEGRATE" prepare "$FIXTURE_ROOT" \
    superteam/100-example-ticket-01-root superteam/100-example-ticket-01-root \
    superteam/100-example-integrate-01-root "$BATS_TEST_TMPDIR/isolated integration"
  [ "$status" -eq 2 ]

  run env "${environment[@]}" bash "$INTEGRATE" prepare "$FIXTURE_ROOT" \
    superteam/100-example superteam/100-example-ticket-01-root \
    superteam/100-example-integrate-01-root "$BATS_TEST_TMPDIR/isolated integration"
  [ "$status" -eq 0 ]
  [ ! -e "$sentinel" ]
}

@test "worktree creation detects hidden untracked files before creating a feature branch" {
  printf '%s\n' hidden > "$FIXTURE_ROOT/hidden.txt"
  git -C "$FIXTURE_ROOT" config status.showUntrackedFiles no
  [ -z "$(git -C "$FIXTURE_ROOT" status --porcelain=v1)" ]

  run bash "$WORKTREE" prepare-feature "$FIXTURE_ROOT" superteam/100-example

  [ "$status" -eq 3 ]
  [[ "$output" == *"Repository baseline is dirty"* ]]
  ! git -C "$FIXTURE_ROOT" show-ref --verify --quiet refs/heads/superteam/100-example
}

@test "worktree and integration checks fail closed before creating branches" {
  shim_dir="$BATS_TEST_TMPDIR/status-error-bin"
  mkdir "$shim_dir"
  real_git=$(command -v git)
  cat > "$shim_dir/git" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  [ "\$argument" != status ] || exit 97
done
exec "$real_git" "\$@"
EOF
  chmod +x "$shim_dir/git"

  run env PATH="$shim_dir:$PATH" bash "$WORKTREE" prepare-feature \
    "$FIXTURE_ROOT" superteam/100-example
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not inspect Repository worktree"* ]]
  ! git -C "$FIXTURE_ROOT" show-ref --verify --quiet refs/heads/superteam/100-example

  bash "$WORKTREE" prepare-feature "$FIXTURE_ROOT" superteam/100-example >/dev/null
  ticket_path="$BATS_TEST_TMPDIR/status-error-ticket"
  bash "$WORKTREE" add-ticket "$FIXTURE_ROOT" superteam/100-example \
    superteam/100-example-ticket-01-root "$ticket_path" >/dev/null
  printf '%s\n' delivered > "$ticket_path/delivered.txt"
  git -C "$ticket_path" add -- delivered.txt
  git -C "$ticket_path" commit -qm delivered
  integration_path="$BATS_TEST_TMPDIR/status-error-integration"

  run env PATH="$shim_dir:$PATH" bash "$INTEGRATE" prepare "$FIXTURE_ROOT" \
    superteam/100-example superteam/100-example-ticket-01-root \
    superteam/100-example-integrate-01-root "$integration_path"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not inspect ticket worktree"* ]]
  [ ! -e "$integration_path" ]
  ! git -C "$FIXTURE_ROOT" show-ref --verify --quiet \
    refs/heads/superteam/100-example-integrate-01-root
}

@test "Implement owns the full Repository Set implementation review fix and integration loop" {
  skill="$ROOT/skills/superteam-implement/SKILL.md"
  prompt="$ROOT/skills/superteam-implement/implementer-prompt.md"
  conflicts="$ROOT/skills/superteam-resolving-merge-conflicts/SKILL.md"
  multi="$ROOT/scripts/st-repository-workflow.sh"

  [ -f "$skill" ]
  [ -f "$prompt" ]
  [ -f "$conflicts" ]
  [ -x "$multi" ]
  grep -Fq 'root-only' "$skill"
  grep -Fq 'Project Snapshot' "$skill"
  grep -Fq "ticket's Repository IDs" "$skill"
  grep -Fq 'Current Contract' "$skill"
  grep -Fq 'fresh implementer' "$skill"
  grep -Fq 'Use stable branch names' "$skill"
  grep -Fq 'st-worktree.sh stable-path' "$skill"
  grep -Fq 'st-repository-workflow.sh prepare' "$skill"
  grep -Fq 'st-repository-workflow.sh promote' "$skill"
  grep -Fq 'integration branch before any canonical feature ref' "$skill"
  grep -Fq 'partial state' "$skill"
  grep -Fq 'submodules' "$skill"
  grep -Fq 'compare-and-swap' "$skill"
  grep -Fq 'A ticket is terminal' "$skill"
  grep -Fq 'tracking-result' "$skill"
  grep -Fq 'must not review code or adjudicate findings' "$skill"
  grep -Fq 'Do not push, create a pull request, or send a message' "$skill"

  grep -Fq 'Use `superteam-tdd`' "$prompt"
  grep -Fq 'Repository Set' "$prompt"
  grep -Fq 'two fresh independent reviewers in parallel' "$prompt"
  grep -Fq 'Standards' "$prompt"
  grep -Fq 'Spec' "$prompt"
  grep -Fq 'stage only the' "$prompt"
  grep -Fq 'ticket files with explicit paths' "$prompt"
  grep -Fq 'Do not modify task or knowledge' "$prompt"
  grep -Fq 'structured Result' "$prompt"

  grep -Fq 'fresh independent agent' "$conflicts"
  grep -Fq 'preserve both intents' "$conflicts"
  grep -Fq 'Do not abort' "$conflicts"
}
