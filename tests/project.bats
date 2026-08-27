#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
PROJECT_REAL="$ROOT/scripts/st-project.sh"
PROJECT="$ROOT/tests/helpers/project-apply.sh"

make_git_root() {
  local directory=$1
  mkdir -p "$directory"
  git -C "$directory" init -q
  git -C "$directory" config user.name "Fixture Contributor"
  git -C "$directory" config user.email "fixture@invalid"
}

make_configured_project() {
  local directory=$1
  make_git_root "$directory"
  mkdir -p "$directory/task" "$directory/knowledge"
  printf '%s\n' \
    'version: 1' \
    'paths:' \
    '  task: "task"' \
    '  knowledge: "knowledge"' > "$directory/superteam.yaml"
}

make_remote_clone() {
  local remote=$1
  local checkout=$2
  git init --bare -q "$remote"
  git --git-dir="$remote" config core.hooksPath /dev/null
  make_git_root "$checkout"
  git -C "$checkout" config core.hooksPath /dev/null
  printf '%s\n' baseline > "$checkout/baseline.txt"
  git -C "$checkout" add -- baseline.txt
  git -C "$checkout" commit -qm baseline
  git -C "$checkout" remote add origin "$remote"
  git -C "$checkout" push -qu origin HEAD
}

advance_remote() {
  local remote=$1
  local updater=$2
  local marker=$3
  git -c core.hooksPath=/dev/null clone -q "$remote" "$updater"
  git -C "$updater" config user.name "Fixture Contributor"
  git -C "$updater" config user.email "fixture@invalid"
  git -C "$updater" config core.hooksPath /dev/null
  printf '%s\n' "$marker" > "$updater/$marker.txt"
  git -C "$updater" add -- "$marker.txt"
  git -C "$updater" commit -qm "$marker"
  git -C "$updater" push -q
}

commit_and_push_project() {
  local project=$1
  git -C "$project" add -- superteam.yaml task knowledge
  if [ -e "$project/.gitignore" ]; then
    git -C "$project" add -- .gitignore
  fi
  git -C "$project" commit -qm 'configure project'
  git -C "$project" push -q
}

repository_result_block() {
  local repository_id=$1
  printf '%s\n' "$output" | LC_ALL=C awk -v header="REPOSITORY: $repository_id" '
    $0 == header { capture = 1 }
    capture && /^REPOSITORY: / && $0 != header { exit }
    capture { print }
  '
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

@test "init previews then creates a root-only Project with confirmed custom asset paths" {
  project="$BATS_TEST_TMPDIR/blank project"
  mkdir "$project"

  run bash "$PROJECT" init "$project" --task "work items" --knowledge "team notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: INIT"* ]]
  [[ "$output" == *"ROOT_MODE: NEW"* ]]
  root="$(cd -P -- "$project" && pwd -P)"
  [[ "$output" == *"CREATE_DIRECTORY: $root/work items"* ]]
  [[ "$output" == *"WRITE: $root/work items/README.md"* ]]
  [[ "$output" == *"CREATE_DIRECTORY: $root/team notes"* ]]
  [[ "$output" == *"WRITE: $root/team notes/README.md"* ]]
  [[ "$output" == *"WRITE: $root/superteam.yaml"* ]]
  [[ "$output" == *"INIT_GIT: $root"* ]]
  [[ "$output" == *"NEXT: Re-run with --apply"* ]]
  [ ! -e "$project/.git" ]
  [ ! -e "$project/superteam.yaml" ]

  run bash "$PROJECT" init "$project" --task "work items" --knowledge "team notes" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: INITIALIZED"* ]]
  [ "$(git -C "$project" rev-parse --show-toplevel)" = "$(cd -P -- "$project" && pwd -P)" ]
  [ "$(cat "$project/superteam.yaml")" = $'version: 1\npaths:\n  task: "work items"\n  knowledge: "team notes"' ]
  [ -d "$project/work items" ]
  [ "$(cat "$project/work items/README.md")" = $'# Superteam task workspace\n\nStore project task artifacts in this directory.' ]
  [ -f "$project/team notes/README.md" ]
  [ ! -e "$project/.git/.superteam-project-owner" ]
  ! git -C "$project" rev-parse --verify HEAD >/dev/null 2>&1
  git -C "$project" diff --cached --quiet
  git -C "$project" add -- superteam.yaml "work items/README.md" "team notes/README.md"
  git -C "$project" ls-files --error-unmatch -- "work items/README.md" "team notes/README.md" superteam.yaml
  git -C "$project" -c user.name='Fixture Contributor' -c user.email='fixture@invalid' commit -qm 'track Superteam assets'
  reopened="$BATS_TEST_TMPDIR/reopened project"
  git clone -q "$project" "$reopened"
  run bash "$PROJECT" inspect "$reopened"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS: CONFIGURED"* ]]
  [ -f "$reopened/work items/README.md" ]
  [ -f "$reopened/team notes/README.md" ]
}

@test "init apply requires the reviewed fingerprint and rejects target state or symlink changes" {
  project="$BATS_TEST_TMPDIR/fingerprint project"
  mkdir "$project"

  run bash "$PROJECT_REAL" init "$project" --task task --knowledge knowledge
  [ "$status" -eq 0 ]
  fingerprint=$(printf '%s\n' "$output" | sed -n 's/^PLAN_FINGERPRINT: //p')
  [ -n "$fingerprint" ]

  run bash "$PROJECT_REAL" init "$project" --task task --knowledge knowledge --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"--plan-fingerprint requires a value"* ]]
  [ ! -e "$project/superteam.yaml" ]

  printf '%s\n' concurrent > "$project/concurrent.txt"
  run bash "$PROJECT_REAL" init "$project" --task task --knowledge knowledge \
    --plan-fingerprint "$fingerprint" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"reviewed initialization plan no longer matches"* ]]
  [ ! -e "$project/superteam.yaml" ]

  first="$BATS_TEST_TMPDIR/first target"
  second="$BATS_TEST_TMPDIR/second target"
  entry="$BATS_TEST_TMPDIR/project entry"
  mkdir "$first" "$second"
  ln -s "$first" "$entry"
  run bash "$PROJECT_REAL" init "$entry" --task task --knowledge knowledge
  [ "$status" -eq 0 ]
  fingerprint=$(printf '%s\n' "$output" | sed -n 's/^PLAN_FINGERPRINT: //p')
  rm "$entry"
  ln -s "$second" "$entry"

  run bash "$PROJECT_REAL" init "$entry" --task task --knowledge knowledge \
    --plan-fingerprint "$fingerprint" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"reviewed initialization plan no longer matches"* ]]
  [ ! -e "$first/superteam.yaml" ]
  [ ! -e "$second/superteam.yaml" ]
}

@test "repository apply rejects a member target changed after the reviewed plan" {
  project="$BATS_TEST_TMPDIR/repository fingerprint project"
  first="$BATS_TEST_TMPDIR/repository fingerprint first"
  second="$BATS_TEST_TMPDIR/repository fingerprint second"
  entry="$BATS_TEST_TMPDIR/repository fingerprint entry"
  make_configured_project "$project"
  make_git_root "$first"
  make_git_root "$second"
  ln -s "$first" "$entry"
  before=$(cat "$project/superteam.yaml")

  run bash "$PROJECT_REAL" repository add "$project" --id api --path "$entry"
  [ "$status" -eq 0 ]
  fingerprint=$(printf '%s\n' "$output" | sed -n 's/^PLAN_FINGERPRINT: //p')
  [ -n "$fingerprint" ]
  rm "$entry"
  ln -s "$second" "$entry"

  run bash "$PROJECT_REAL" repository add "$project" --id api --path "$entry" \
    --plan-fingerprint "$fingerprint" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"reviewed Repository Set plan no longer matches"* ]]
  [ "$(cat "$project/superteam.yaml")" = "$before" ]
}

@test "adopt reuses an existing Git root without staging, committing, changing files, or changing remotes" {
  project="$BATS_TEST_TMPDIR/existing"
  make_git_root "$project"
  printf '%s\n' 'keep this user file' > "$project/user file"
  git -C "$project" add -- "user file"
  git -C "$project" commit -qm "fixture baseline"
  git -C "$project" remote add origin ../remote-placeholder
  before_remote="$(git -C "$project" remote -v)"
  before_user_file="$(cat "$project/user file")"

  run bash "$PROJECT" adopt "$project" --task delivery --knowledge notes --apply
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = 'ACTION: ADOPT' ]
  [[ "$output" == *"ROOT_MODE: EXISTING"* ]]
  [ "$(cat "$project/user file")" = "$before_user_file" ]
  [ "$(git -C "$project" remote -v)" = "$before_remote" ]
  git -C "$project" diff --cached --quiet
  [ -z "$(git -C "$project" diff --cached --name-only)" ]
  [ "$(git -C "$project" rev-list --count HEAD)" = "1" ]
  [ -f "$project/superteam.yaml" ]
}

@test "initialization plan lists each missing parent directory exactly once" {
  project="$BATS_TEST_TMPDIR/nested plan"
  mkdir "$project"
  root="$(cd -P -- "$project" && pwd -P)"

  run bash "$PROJECT" init "$project" --task assets/task --knowledge assets/knowledge
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -Fxc "CREATE_DIRECTORY: $root/assets")" -eq 1 ]
  [[ "$output" == *"CREATE_DIRECTORY: $root/assets/task"* ]]
  [[ "$output" == *"CREATE_DIRECTORY: $root/assets/knowledge"* ]]
  [[ "$output" == *"WRITE: $root/assets/task/README.md"* ]]
  [[ "$output" == *"WRITE: $root/assets/knowledge/README.md"* ]]
  [ ! -e "$project/assets" ]
}

@test "existing task and knowledge directories require separate explicit adoption and never overwrite files" {
  project="$BATS_TEST_TMPDIR/adopt assets"
  make_git_root "$project"
  mkdir "$project/existing task" "$project/existing knowledge"
  printf '%s\n' 'task marker' > "$project/existing task/marker"
  printf '%s\n' 'knowledge marker' > "$project/existing knowledge/marker"

  run bash "$PROJECT" init "$project" --task "existing task" --knowledge "existing knowledge" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"--adopt-task"* ]]
  [ ! -e "$project/superteam.yaml" ]
  [ "$(cat "$project/existing task/marker")" = "task marker" ]
  [ "$(cat "$project/existing knowledge/marker")" = "knowledge marker" ]

  run bash "$PROJECT" init "$project" --task "existing task" --knowledge "existing knowledge" --adopt-task --adopt-knowledge --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADOPT_DIRECTORY: $(cd -P -- "$project" && pwd -P)/existing task"* ]]
  [[ "$output" == *"ADOPT_DIRECTORY: $(cd -P -- "$project" && pwd -P)/existing knowledge"* ]]
  [[ "$output" != *"existing task/README.md"* ]]
  [[ "$output" != *"existing knowledge/README.md"* ]]
  [ -f "$project/superteam.yaml" ]
  [ "$(cat "$project/existing task/marker")" = "task marker" ]
  [ "$(cat "$project/existing knowledge/marker")" = "knowledge marker" ]
  [ ! -e "$project/existing knowledge/README.md" ]
}

@test "path collisions, nesting, root escapes, files, and symbolic links fail before any initialization write" {
  for variant in same nested parent absolute tilde git git_mixed_case file link; do
    project="$BATS_TEST_TMPDIR/$variant"
    mkdir "$project"
    case "$variant" in
      same)
        args=(--task task --knowledge task)
        ;;
      nested)
        args=(--task task --knowledge task/notes)
        ;;
      parent)
        args=(--task ../task --knowledge notes)
        ;;
      absolute)
        args=(--task /tmp/task --knowledge notes)
        ;;
      tilde)
        args=(--task '~task' --knowledge notes)
        ;;
      git)
        args=(--task .git/superteam --knowledge notes)
        ;;
      git_mixed_case)
        args=(--task .GIT/superteam --knowledge notes)
        ;;
      file)
        printf '%s\n' marker > "$project/task"
        args=(--task task --knowledge notes)
        ;;
      link)
        outside="$BATS_TEST_TMPDIR/outside-$variant"
        mkdir "$outside"
        ln -s "$outside" "$project/asset-link"
        args=(--task asset-link/items --knowledge notes)
        ;;
    esac

    run bash "$PROJECT" init "$project" "${args[@]}" --apply
    [ "$status" -ne 0 ]
    [ ! -e "$project/.git" ]
    [ ! -e "$project/superteam.yaml" ]
  done
}

@test "SIGINT, HUP, and TERM abort initialization, roll back owned assets, and release the lock" {
  for signal_name in HUP INT TERM; do
    project="$BATS_TEST_TMPDIR/signal-abort-$signal_name"
    make_git_root "$project"
    project="$(cd -P -- "$project" && pwd -P)"
    shim_dir="$BATS_TEST_TMPDIR/bin-signal-abort-$signal_name"
    mkdir "$shim_dir"
    printf '%s\n' '#!/usr/bin/env bash' \
      'destination=""; for argument in "$@"; do destination=$argument; done' \
      'if [ "$destination" = "$SUPERTEAM_TEST_TASK/README.md" ] || { [ "$PWD" = "$SUPERTEAM_TEST_TASK" ] && { [ "$destination" = README.md ] || [ "$destination" = ./README.md ]; }; }; then' \
      '  /bin/ln "$@" || exit $?' \
      '  : > "$SUPERTEAM_TEST_SENTINEL"' \
      '  transaction_pid=$(ps -o ppid= -p "$PPID" | tr -d " ")' \
      '  kill -"$SUPERTEAM_TEST_SIGNAL" "$transaction_pid"' \
      '  exit 0' \
      'fi' \
      'exec /bin/ln "$@"' > "$shim_dir/ln"
    chmod +x "$shim_dir/ln"

    sentinel="$BATS_TEST_TMPDIR/signal-injected-$signal_name"
    run env PATH="$shim_dir:$PATH" SUPERTEAM_TEST_TASK="$project/task" SUPERTEAM_TEST_SIGNAL="$signal_name" SUPERTEAM_TEST_SENTINEL="$sentinel" \
      bash "$PROJECT" init "$project" --task task --knowledge knowledge --apply
    [ "$status" -ne 0 ]
    [ -f "$sentinel" ]
    [[ "$output" != *"RESULT: INITIALIZED"* ]]
    [ ! -e "$project/task" ]
    [ ! -e "$project/knowledge" ]
    [ ! -e "$project/superteam.yaml" ]
    [ ! -e "$project/.superteam-project.lock" ]
  done
}

@test "asset paths with a dash-prefixed leaf initialize normally" {
  project="$BATS_TEST_TMPDIR/dash-leaf-assets"
  make_git_root "$project"

  run bash "$PROJECT" init "$project" --task -tasks --knowledge -knowledge --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: INITIALIZED"* ]]
  [ -f "$project/-tasks/README.md" ]
  [ -f "$project/-knowledge/README.md" ]
}

@test "Git environment pollution is ignored for init, doctor, and status" {
  project="$BATS_TEST_TMPDIR/git-environment-root"
  outside="$BATS_TEST_TMPDIR/git-environment-outside"
  mkdir "$project" "$outside"
  project="$(cd -P -- "$project" && pwd -P)"
  outside="$(cd -P -- "$outside" && pwd -P)"
  environment=(GIT_DIR="$outside/git-dir" GIT_WORK_TREE="$outside/worktree" GIT_COMMON_DIR="$outside/common" \
    GIT_INDEX_FILE="$outside/index" GIT_OBJECT_DIRECTORY="$outside/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$outside/alternate")

  run env "${environment[@]}" bash "$PROJECT" init "$project" --task task --knowledge knowledge --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: INITIALIZED"* ]]
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ]

  run env "${environment[@]}" bash "$PROJECT" doctor "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MANIFEST: VALID"* ]]
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ]

  run env "${environment[@]}" bash "$PROJECT" status "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS: CONFIGURED"* ]]
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ]
}

@test "initialization does not require Git init.defaultBranch support" {
  project="$BATS_TEST_TMPDIR/old-git-init"
  mkdir "$project"
  shim_dir="$BATS_TEST_TMPDIR/bin-old-git-init"
  mkdir "$shim_dir"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = -c ]; then exit 71; fi' \
    'exec /usr/bin/git "$@"' > "$shim_dir/git"
  chmod +x "$shim_dir/git"

  run env PATH="$shim_dir:$PATH" bash "$PROJECT" init "$project" --task task --knowledge knowledge --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: INITIALIZED"* ]]
}

@test "internal lock and staging paths cannot be adopted as Project assets" {
  project="$BATS_TEST_TMPDIR/internal-paths"
  make_git_root "$project"

  for reserved in .superteam-project.lock/assets .superteam-project-stage.123/task .superteam-project-probe/task; do
    run bash "$PROJECT" init "$project" --task "$reserved" --knowledge knowledge --adopt-task --apply
    [ "$status" -ne 0 ]
    [ ! -e "$project/superteam.yaml" ]
    [ ! -e "$project/.superteam-project.lock" ]
  done
}

@test "missing command prints usage and exits with code 2" {
  run bash "$PROJECT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "init and manifest parsing reject control characters without echoing the unsafe path" {
  for separator in $'\t' $'\033'; do
    project="$BATS_TEST_TMPDIR/control-$RANDOM"
    mkdir "$project"
    unsafe="task${separator}name"
    run bash "$PROJECT" init "$project" --task "$unsafe" --knowledge knowledge --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported control character"* ]]
    [[ "$output" != *"$unsafe"* ]]
    [ ! -e "$project/.git" ]
  done

  project="$BATS_TEST_TMPDIR/control-manifest"
  make_git_root "$project"
  mkdir "$project/knowledge"
  printf 'version: 1\npaths:\n  task: "task\tname"\n  knowledge: "knowledge"\n' > "$project/superteam.yaml"
  run bash "$PROJECT" doctor "$project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid Canonical Superteam YAML"* ]]
  [[ "$output" != *$'\t'* ]]
}

@test "nested Git repositories cannot be adopted or used as new asset ancestors" {
  project="$BATS_TEST_TMPDIR/nested-repository-parent"
  source="$BATS_TEST_TMPDIR/nested-repository-source"
  make_git_root "$project"
  make_git_root "$source"
  git clone -q "$source" "$project/cloned-repository"

  run bash "$PROJECT" init "$project" --task cloned-repository --knowledge knowledge --adopt-task --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not be inside an independent Git Repository"* ]]
  [ ! -e "$project/superteam.yaml" ]
  [ ! -e "$project/knowledge" ]

  run bash "$PROJECT" init "$project" --task cloned-repository/tasks --knowledge knowledge --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not be inside an independent Git Repository"* ]]
  [ ! -e "$project/superteam.yaml" ]
  [ ! -e "$project/knowledge" ]
}

@test "inspect, status, and doctor expose the same configured root-only snapshot" {
  project="$BATS_TEST_TMPDIR/configured"
  mkdir "$project"
  run bash "$PROJECT" init "$project" --task task --knowledge knowledge --apply
  [ "$status" -eq 0 ]
  root="$(cd -P -- "$project" && pwd -P)"

  for action in inspect status doctor; do
    run bash "$PROJECT" "$action" "$project"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STATUS: CONFIGURED"* ]]
    [[ "$output" == *"ROOT: $root"* ]]
    [[ "$output" == *"REPOSITORY: root"* ]]
    [[ "$output" == *"TASK: $root/task"* ]]
    [[ "$output" == *"KNOWLEDGE: $root/knowledge"* ]]
  done
  ! grep -q '^repositories:' "$project/superteam.yaml"
}

@test "configured snapshots report untracked, staged, and committed initialization assets" {
  project="$BATS_TEST_TMPDIR/tracking-state"
  mkdir "$project"
  run bash "$PROJECT" init "$project" --task task --knowledge knowledge --apply
  [ "$status" -eq 0 ]

  for action in inspect status doctor; do
    run bash "$PROJECT" "$action" "$project"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MANIFEST_TRACKING: UNTRACKED"* ]]
    [[ "$output" == *"TASK_TRACKING: UNTRACKED"* ]]
    [[ "$output" == *"KNOWLEDGE_TRACKING: UNTRACKED"* ]]
  done

  git -C "$project" add -- superteam.yaml task/README.md knowledge/README.md
  for action in inspect status doctor; do
    run bash "$PROJECT" "$action" "$project"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MANIFEST_TRACKING: STAGED"* ]]
    [[ "$output" == *"TASK_TRACKING: STAGED"* ]]
    [[ "$output" == *"KNOWLEDGE_TRACKING: STAGED"* ]]
  done

  git -C "$project" -c user.name='Fixture Contributor' -c user.email='fixture@invalid' commit -qm 'track initialization assets'
  for action in inspect status doctor; do
    run bash "$PROJECT" "$action" "$project"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MANIFEST_TRACKING: COMMITTED"* ]]
    [[ "$output" == *"TASK_TRACKING: COMMITTED"* ]]
    [[ "$output" == *"KNOWLEDGE_TRACKING: COMMITTED"* ]]
  done

  printf '%s\n' 'unstaged edit' >> "$project/task/README.md"
  rm "$project/knowledge/README.md"
  for action in inspect status doctor; do
    run bash "$PROJECT" "$action" "$project"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MANIFEST_TRACKING: COMMITTED"* ]]
    [[ "$output" == *"TASK_TRACKING: UNCOMMITTED"* ]]
    [[ "$output" == *"KNOWLEDGE_TRACKING: UNCOMMITTED"* ]]
  done
}

@test "strict Canonical Superteam YAML rejects unknown, duplicate, and complex forms without a fallback" {
  for body in unknown duplicate complex; do
    project="$BATS_TEST_TMPDIR/invalid-$body"
    make_git_root "$project"
    mkdir "$project/task" "$project/knowledge"
    case "$body" in
      unknown)
        printf '%s\n' 'version: 1' 'paths:' '  task: "task"' '  knowledge: "knowledge"' 'owner: "someone"' > "$project/superteam.yaml"
        ;;
      duplicate)
        printf '%s\n' 'version: 1' 'paths:' '  task: "task"' '  task: "other"' '  knowledge: "knowledge"' > "$project/superteam.yaml"
        ;;
      complex)
        printf '%s\n' 'version: 1' 'paths:' '  task: &task "task"' '  knowledge: *task' > "$project/superteam.yaml"
        ;;
    esac

    for action in inspect status doctor; do
      run bash "$PROJECT" "$action" "$project"
      [ "$status" -ne 0 ]
      [[ "$output" == *"ERROR: invalid Canonical Superteam YAML"* ]]
      [ "$(cat "$project/superteam.yaml")" != "" ]
    done
  done
}

@test "configured snapshots reject a nested Git root" {
  project="$BATS_TEST_TMPDIR/snapshot-nested-root"
  mkdir "$project"
  run bash "$PROJECT" init "$project" --task task --knowledge knowledge --apply
  [ "$status" -eq 0 ]
  git -C "$project/task" init -q
  for action in inspect status doctor; do
    run bash "$PROJECT" "$action" "$project"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid Canonical Superteam YAML"* ]]
  done
}

@test "path handling is deterministic for Unicode, quotes, and a symbolic-link Project entry point" {
  project="$BATS_TEST_TMPDIR/-项目 space 'quote'"
  mkdir "$project"
  run bash "$PROJECT" init "$project" --task '任务 "queue"' --knowledge "notes 'team'" --apply
  [ "$status" -eq 0 ]
  root="$(cd -P -- "$project" && pwd -P)"
  grep -Fq 'task: "任务 \"queue\""' "$project/superteam.yaml"
  grep -Fq 'knowledge: "notes '\''team'\''"' "$project/superteam.yaml"

  entry="$BATS_TEST_TMPDIR/project entry"
  ln -s "$project" "$entry"
  for action in inspect status doctor; do
    run bash "$PROJECT" "$action" "$entry"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ROOT: $root"* ]]
    [[ "$output" == *"TASK: $root/任务 \"queue\""* ]]
    [[ "$output" == *"KNOWLEDGE: $root/notes 'team'"* ]]
  done
}

@test "inspect reports direct child repository candidates without managing them" {
  parent="$BATS_TEST_TMPDIR/project parent"
  child="$parent/child repository"
  mkdir -p "$child"
  git -C "$child" init -q
  child_root="$(cd -P -- "$child" && pwd -P)"

  run bash "$PROJECT" inspect "$parent"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS: UNINITIALIZED"* ]]
  [[ "$output" == *"CANDIDATE_ROOT: $child_root"* ]]
  [ ! -e "$parent/.git" ]
}

@test "doctor checks the supported runtime before Project initialization without writing" {
  project="$BATS_TEST_TMPDIR/doctor runtime"
  mkdir "$project"
  before="$(find "$project" -mindepth 1 -print)"

  run bash "$PROJECT" doctor "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK_GIT: PASS"* ]]
  [[ "$output" == *"CHECK_BASH: PASS"* ]]
  [[ "$output" == *"CHECK_PLATFORM: PASS"* ]]
  for command in awk basename cat cksum cp find grep ln ls mkdir mv readlink rm rmdir sed sort tail tr wc; do
    [[ "$output" == *"CHECK_COMMAND_${command}: PASS"* ]]
  done
  [[ "$output" == *"CHECK_PROJECT: INCONCLUSIVE"* ]]
  [[ "$output" == *"CHECK_MANIFEST: INCONCLUSIVE"* ]]
  [[ "$output" == *"DOCTOR_RESULT: INCONCLUSIVE"* ]]
  [ "$(find "$project" -mindepth 1 -print)" = "$before" ]
  [[ "$output" == *"CHECK_GIT: PASS"* ]] || return 1
}

@test "doctor diagnoses an old Bash without writing" {
  project="$BATS_TEST_TMPDIR/doctor old bash"
  mkdir "$project"
  real_bash=$(command -v bash)

  old_bash_bin="$BATS_TEST_TMPDIR/doctor-old-bash-bin"
  mkdir "$old_bash_bin"
  cat > "$old_bash_bin/bash" <<EOF
#!$real_bash
if [ "\${1:-}" = -c ]; then printf '%s\n' 3.1; exit 0; fi
exec "$real_bash" "\$@"
EOF
  chmod +x "$old_bash_bin/bash"
  run env PATH="$old_bash_bin:$PATH" "$real_bash" "$PROJECT" doctor "$project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHECK_BASH: FAIL"* ]]
  [[ "$output" == *"Install Bash 3.2 or newer"* ]]
  [[ "$output" == *"DOCTOR_RESULT: FAIL"* ]]
  [ -z "$(find "$project" -mindepth 1 -print)" ]
}

@test "doctor diagnoses an unsupported native Windows shell without writing" {
  project="$BATS_TEST_TMPDIR/doctor unsupported platform"
  mkdir "$project"
  real_bash=$(command -v bash)
  real_uname=$(command -v uname)

  platform_bin="$BATS_TEST_TMPDIR/doctor-platform-bin"
  mkdir "$platform_bin"
  cat > "$platform_bin/uname" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -s ] && { printf '%s\n' MINGW64_NT; exit 0; }
exec "$real_uname" "\$@"
EOF
  chmod +x "$platform_bin/uname"
  run env PATH="$platform_bin:$PATH" "$real_bash" "$PROJECT" doctor "$project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHECK_PLATFORM: FAIL"* ]]
  [[ "$output" == *"native Windows shells are unsupported"* ]]
  [ -z "$(find "$project" -mindepth 1 -print)" ]
}

@test "doctor diagnoses a missing required POSIX command without writing" {
  project="$BATS_TEST_TMPDIR/doctor missing command"
  mkdir "$project"
  real_bash=$(command -v bash)

  missing_bin="$BATS_TEST_TMPDIR/doctor-missing-bin"
  mkdir "$missing_bin"
  for command in bash git uname basename cat cksum cp find grep ln ls mkdir mv readlink rm rmdir sed sort tail tr wc; do
    command_path=$(command -v "$command")
    ln -s "$command_path" "$missing_bin/$command"
  done
  run env PATH="$missing_bin" "$real_bash" "$PROJECT" doctor "$project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHECK_COMMAND_awk: FAIL"* ]]
  [[ "$output" == *"Install a POSIX implementation of awk"* ]]
  [ -z "$(find "$project" -mindepth 1 -print)" ]
}

@test "doctor recognizes WSL as the supported Linux contract" {
  project="$BATS_TEST_TMPDIR/doctor wsl"
  mkdir "$project"
  real_bash=$(command -v bash)
  shim_dir="$BATS_TEST_TMPDIR/doctor-wsl-bin"
  mkdir "$shim_dir"
  cat > "$shim_dir/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' Linux ;;
  -r) printf '%s\n' "$SUPERTEAM_TEST_RELEASE" ;;
  *) exit 91 ;;
esac
EOF
  chmod +x "$shim_dir/uname"

  run env PATH="$shim_dir:$PATH" SUPERTEAM_TEST_RELEASE='5.15.153.1-microsoft-standard-WSL2' \
    "$real_bash" "$PROJECT" doctor "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK_PLATFORM: PASS"* ]]
  [[ "$output" == *"CHECK_PLATFORM_DETAIL: WSL (Linux contract)."* ]]
}

@test "doctor recognizes a native Linux fixture as supported" {
  project="$BATS_TEST_TMPDIR/doctor linux"
  mkdir "$project"
  real_bash=$(command -v bash)
  shim_dir="$BATS_TEST_TMPDIR/doctor-linux-bin"
  mkdir "$shim_dir"
  cat > "$shim_dir/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' Linux ;;
  -r) printf '%s\n' '6.8.0-generic' ;;
  *) exit 91 ;;
esac
EOF
  chmod +x "$shim_dir/uname"

  run env PATH="$shim_dir:$PATH" "$real_bash" "$PROJECT" doctor "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK_PLATFORM: PASS"* ]]
  [[ "$output" == *"CHECK_PLATFORM_DETAIL: Linux."* ]]
}

@test "doctor recognizes a deterministic Darwin fixture as supported macOS" {
  project="$BATS_TEST_TMPDIR/doctor darwin"
  mkdir "$project"
  real_bash=$(command -v bash)
  shim_dir="$BATS_TEST_TMPDIR/doctor-darwin-bin"
  mkdir "$shim_dir"
  cat > "$shim_dir/uname" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -s ] || exit 91
printf '%s\n' Darwin
EOF
  chmod +x "$shim_dir/uname"

  run env PATH="$shim_dir:$PATH" "$real_bash" "$PROJECT" doctor "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK_PLATFORM: PASS"* ]]
  [[ "$output" == *"CHECK_PLATFORM_DETAIL: macOS."* ]]
}

@test "metadata-only initialization previews child repositories and leaves a refusal unchanged" {
  parent="$BATS_TEST_TMPDIR/metadata-only preview"
  child="$parent/service api"
  mkdir -p "$child"
  git -C "$child" init -q
  printf '%s\n' 'parent notes' > "$parent/notes.txt"
  child_root="$(cd -P -- "$child" && pwd -P)"
  root="$(cd -P -- "$parent" && pwd -P)"

  run bash "$PROJECT" init "$parent" --task task --knowledge knowledge
  [ "$status" -eq 0 ]
  [[ "$output" == *"ROOT_MODE: METADATA_ONLY"* ]]
  [[ "$output" == *"CANDIDATE_ROOT: $child_root"* ]]
  [[ "$output" == *"WRITE: $root/.gitignore"* ]]
  [[ "$output" == *"INIT_GIT: $root"* ]]
  [[ "$output" == *"GIT_STAGE: NONE"* ]]
  [[ "$output" == *"GIT_COMMIT: NONE"* ]]
  [ "$(cat "$parent/notes.txt")" = 'parent notes' ]
  [ ! -e "$parent/.git" ]
  [ ! -e "$parent/.gitignore" ]
  [ ! -e "$parent/superteam.yaml" ]
}

@test "metadata-only initialization uses an allowlist and does not register candidates" {
  parent="$BATS_TEST_TMPDIR/metadata-only apply"
  child="$parent/service-api"
  mkdir -p "$child"
  git -C "$child" init -q
  printf '%s\n' 'keep parent content' > "$parent/unrelated.txt"

  run bash "$PROJECT" init "$parent" --task task --knowledge knowledge --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: INITIALIZED"* ]]
  [[ "$output" == *"HEAD: UNBORN"* ]]
  [[ "$output" == *"INITIALIZATION_COMMIT: AVAILABLE"* ]]
  [ "$(cat "$parent/unrelated.txt")" = 'keep parent content' ]
  [ -d "$child/.git" ]
  [ -f "$parent/.gitignore" ]
  ! grep -q '^repositories:' "$parent/superteam.yaml"
  ! git -C "$parent" rev-parse --verify HEAD >/dev/null 2>&1
  [ -z "$(git -C "$parent" remote)" ]
  [ "$(git -C "$parent" status --porcelain --untracked-files=all)" = $'?? .gitignore\n?? knowledge/README.md\n?? superteam.yaml\n?? task/README.md' ]
  git -C "$parent" check-ignore -q -- unrelated.txt
  git -C "$parent" check-ignore -q -- service-api
  ! git -C "$parent" check-ignore -q -- .gitignore
  ! git -C "$parent" check-ignore -q -- superteam.yaml
  ! git -C "$parent" check-ignore -q -- task/README.md
  ! git -C "$parent" check-ignore -q -- knowledge/README.md
}

@test "metadata-only allowlist opens every parent of custom nested asset paths" {
  parent="$BATS_TEST_TMPDIR/metadata-only nested"
  mkdir -p "$parent/component/.git"
  mkdir -p "$parent/workspace"
  printf '%s\n' 'unrelated' > "$parent/workspace/placeholder"
  task_path='workspace/[team]/tasks *'
  knowledge_path='workspace/[team]/notes ?'

  run bash "$PROJECT" init "$parent" \
    --task "$task_path" --knowledge "$knowledge_path" --apply
  [ "$status" -eq 0 ]
  untracked="$(git -C "$parent" ls-files --others --exclude-standard -z | tr '\0' '\n' | LC_ALL=C sort)"
  [ "$untracked" = $'.gitignore\nsuperteam.yaml\nworkspace/[team]/notes ?/README.md\nworkspace/[team]/tasks */README.md' ]
  git -C "$parent" check-ignore -q -- workspace/placeholder
  ! git -C "$parent" check-ignore -q -- "$task_path/README.md"
  ! git -C "$parent" check-ignore -q -- "$knowledge_path/README.md"
}

@test "metadata-only initialization never overwrites a parent .gitignore" {
  parent="$BATS_TEST_TMPDIR/metadata-only existing gitignore"
  mkdir -p "$parent/service/.git"
  printf '%s\n' '*.private' > "$parent/.gitignore"

  run bash "$PROJECT" init "$parent" --task task --knowledge knowledge
  [ "$status" -ne 0 ]
  [[ "$output" == *".gitignore already exists"* ]]
  [ "$(cat "$parent/.gitignore")" = '*.private' ]
  [ ! -e "$parent/.git" ]
  [ ! -e "$parent/superteam.yaml" ]
}

@test "initialization commit requires a second apply and commits only planned metadata assets" {
  parent="$BATS_TEST_TMPDIR/metadata-only commit"
  child="$parent/service-api"
  mkdir -p "$child"
  git -C "$child" init -q
  printf '%s\n' 'keep parent content' > "$parent/unrelated.txt"
  run bash "$PROJECT" init "$parent" --task task --knowledge knowledge --apply
  [ "$status" -eq 0 ]
  git -C "$parent" config user.name 'Fixture Contributor'
  git -C "$parent" config user.email 'fixture@invalid'

  run bash "$PROJECT" init-commit "$parent"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: INITIALIZATION_COMMIT"* ]]
  [[ "$output" == *"GIT_STAGE: .gitignore"* ]]
  [[ "$output" == *"GIT_STAGE: superteam.yaml"* ]]
  [[ "$output" == *"GIT_STAGE: task"* ]]
  [[ "$output" == *"GIT_STAGE: knowledge"* ]]
  [[ "$output" == *"GIT_COMMIT: Initialize Superteam project"* ]]
  [[ "$output" == *"HEAD: UNBORN"* ]]
  ! git -C "$parent" rev-parse --verify HEAD >/dev/null 2>&1
  git -C "$parent" diff --cached --quiet

  run bash "$PROJECT" init-commit "$parent" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: INITIALIZATION_COMMITTED"* ]]
  git -C "$parent" rev-parse --verify HEAD >/dev/null
  [ "$(git -C "$parent" show --pretty= --name-only HEAD | LC_ALL=C sort)" = $'.gitignore\nknowledge/README.md\nsuperteam.yaml\ntask/README.md' ]
  [ "$(git -C "$parent" status --porcelain --untracked-files=all)" = '' ]
  [ -d "$child/.git" ]
  [ "$(cat "$parent/unrelated.txt")" = 'keep parent content' ]
  [ -z "$(git -C "$parent" remote)" ]
}

@test "initialization commit uses the default global identity through the isolated Git boundary" {
  parent="$BATS_TEST_TMPDIR/global identity parent"
  home="$BATS_TEST_TMPDIR/global identity home"
  attacker="$BATS_TEST_TMPDIR/attacker.gitconfig"
  mkdir -p "$parent/service/.git" "$home"
  run bash "$PROJECT" init "$parent" --task task --knowledge knowledge --apply
  [ "$status" -eq 0 ]
  ! git -C "$parent" config --local --get user.name >/dev/null 2>&1
  git config --file "$home/.gitconfig" user.name 'Global Fixture'
  git config --file "$home/.gitconfig" user.email 'global-fixture@invalid'
  git config --file "$attacker" user.name 'Injected Config'
  git config --file "$attacker" user.email 'injected-config@invalid'

  run env HOME="$home" GIT_CONFIG_GLOBAL="$attacker" \
    GIT_AUTHOR_NAME='Injected Author' GIT_AUTHOR_EMAIL='injected-author@invalid' \
    GIT_COMMITTER_NAME='Injected Committer' GIT_COMMITTER_EMAIL='injected-committer@invalid' \
    bash "$PROJECT_REAL" init-commit "$parent" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: INITIALIZATION_COMMITTED"* ]]
  [ "$(git -C "$parent" show -s --format='%an%n%ae%n%cn%n%ce' HEAD)" = \
    $'Global Fixture\nglobal-fixture@invalid\nGlobal Fixture\nglobal-fixture@invalid' ]
}

@test "initialization commit treats every confirmed asset as a literal Git pathspec" {
  parent="$BATS_TEST_TMPDIR/literal initialization pathspec"
  task_path='task*[x]?\assets'
  knowledge_path=':(glob)knowledge*'
  mkdir -p "$parent/service/.git"

  run bash "$PROJECT" init "$parent" --task "$task_path" \
    --knowledge "$knowledge_path" --apply
  [ "$status" -eq 0 ]
  git -C "$parent" config user.name 'Fixture Contributor'
  git -C "$parent" config user.email 'fixture@invalid'
  mkdir -p "$parent/taskABxZassets" "$parent/knowledge-decoy"
  printf '%s\n' decoy > "$parent/taskABxZassets/decoy.txt"
  printf '%s\n' decoy > "$parent/knowledge-decoy/decoy.txt"

  run bash "$PROJECT" init-commit "$parent" --apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: INITIALIZATION_COMMITTED"* ]]
  tracked=$(git -C "$parent" ls-tree -r --name-only -z HEAD | tr '\0' '\n' | LC_ALL=C sort)
  expected=$(printf '%s\n' .gitignore superteam.yaml \
    "$task_path/README.md" "$knowledge_path/README.md" | LC_ALL=C sort)
  [ "$tracked" = "$expected" ]
  [[ "$tracked" != *"decoy.txt"* ]]
}

@test "Project status exposes config-hidden dirtiness and fails closed on status errors" {
  project="$BATS_TEST_TMPDIR/project dirty helper"
  make_configured_project "$project"
  git -C "$project" add -- superteam.yaml task knowledge
  git -C "$project" commit -qm project
  printf '%s\n' hidden > "$project/hidden.txt"
  git -C "$project" config status.showUntrackedFiles no
  [ -z "$(git -C "$project" status --porcelain=v1)" ]

  run bash "$PROJECT" status "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WORKTREE: DIRTY"* ]]

  shim_dir="$BATS_TEST_TMPDIR/project-status-error-bin"
  mkdir "$shim_dir"
  real_git=$(command -v git)
  cat > "$shim_dir/git" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  [ "\$argument" != status ] || exit 95
done
exec "$real_git" "\$@"
EOF
  chmod +x "$shim_dir/git"

  run env PATH="$shim_dir:$PATH" bash "$PROJECT" status "$project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"WORKTREE: ERROR"* ]]
}

@test "Project Init never stages or commits an existing Root Repository without HEAD" {
  project="$BATS_TEST_TMPDIR/existing unborn"
  make_git_root "$project"
  printf '%s\n' 'existing file' > "$project/existing.txt"

  run bash "$PROJECT" init "$project" --task task --knowledge knowledge --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"ROOT_MODE: EXISTING"* ]]
  [[ "$output" == *"GIT_STAGE: NONE"* ]]
  [[ "$output" == *"GIT_COMMIT: NONE"* ]]
  [[ "$output" != *"INITIALIZATION_COMMIT: AVAILABLE"* ]]
  ! git -C "$project" rev-parse --verify HEAD >/dev/null 2>&1
  git -C "$project" diff --cached --quiet
  [ ! -e "$project/.gitignore" ]
  [ -f "$project/existing.txt" ]
}

@test "a failed initialization commit keeps the generated assets and restores an empty index" {
  parent="$BATS_TEST_TMPDIR/metadata-only failed commit"
  mkdir -p "$parent/service/.git"
  printf '%s\n' unrelated > "$parent/unrelated.txt"
  run bash "$PROJECT" init "$parent" --task task --knowledge knowledge --apply
  [ "$status" -eq 0 ]
  real_git="$(command -v git)"
  shim_dir="$BATS_TEST_TMPDIR/bin-failed-initialization-commit"
  mkdir "$shim_dir"
  printf '%s\n' '#!/usr/bin/env bash' \
    "real_git='$real_git'" \
    'for argument in "$@"; do' \
    '  if [ "$argument" = commit ]; then' \
    '    "$real_git" -C "$SUPERTEAM_TEST_ROOT" add -f -- unrelated.txt || exit $?' \
    '    exit 75' \
    '  fi' \
    'done' \
    'exec "$real_git" "$@"' > "$shim_dir/git"
  chmod +x "$shim_dir/git"

  run env PATH="$shim_dir:$PATH" SUPERTEAM_TEST_ROOT="$parent" \
    bash "$PROJECT" init-commit "$parent" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not create the first local commit"* ]]
  ! git -C "$parent" rev-parse --verify HEAD >/dev/null 2>&1
  git -C "$parent" diff --cached --quiet
  ! git -C "$parent" ls-files --error-unmatch -- unrelated.txt >/dev/null 2>&1
  [ -f "$parent/.gitignore" ]
  [ -f "$parent/superteam.yaml" ]
  [ -f "$parent/task/README.md" ]
  [ -f "$parent/knowledge/README.md" ]
}

@test "initialization commit disables repository hooks for both success and failure hooks" {
  for hook_status in 0 1; do
    parent="$BATS_TEST_TMPDIR/metadata-only hook-$hook_status"
    mkdir -p "$parent/service/.git"
    printf '%s\n' unrelated > "$parent/unrelated.txt"
    run bash "$PROJECT" init "$parent" --task task --knowledge knowledge --apply
    [ "$status" -eq 0 ]
    git -C "$parent" config user.name 'Fixture Contributor'
    git -C "$parent" config user.email 'fixture@invalid'
    mkdir -p "$parent/.git/hooks"
    sentinel="$BATS_TEST_TMPDIR/hook-$hook_status-ran"
    printf '%s\n' '#!/usr/bin/env bash' \
      '/usr/bin/git add -f -- unrelated.txt' \
      ': > "$SUPERTEAM_TEST_SENTINEL"' \
      "exit $hook_status" > "$parent/.git/hooks/pre-commit"
    chmod +x "$parent/.git/hooks/pre-commit"

    run env SUPERTEAM_TEST_SENTINEL="$sentinel" \
      bash "$PROJECT" init-commit "$parent" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: INITIALIZATION_COMMITTED"* ]]
    [ ! -e "$sentinel" ]
    ! git -C "$parent" ls-tree -r --name-only HEAD | grep -Fqx -- unrelated.txt
    git -C "$parent" diff --cached --quiet
  done
}

@test "metadata-only initialization rolls back generated assets after a normal apply failure" {
  parent="$BATS_TEST_TMPDIR/metadata-only rollback"
  child="$parent/service"
  mkdir -p "$child"
  git -C "$child" init -q
  printf '%s\n' 'keep parent content' > "$parent/unrelated.txt"
  parent="$(cd -P -- "$parent" && pwd -P)"
  shim_dir="$BATS_TEST_TMPDIR/bin-metadata-only-rollback"
  mkdir "$shim_dir"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "$PWD" = "$SUPERTEAM_TEST_ROOT" ] && { [ "${3:-}" = ./superteam.yaml ] || [ "${3:-}" = superteam.yaml ]; }; then exit 75; fi' \
    'exec /bin/ln "$@"' > "$shim_dir/ln"
  chmod +x "$shim_dir/ln"

  run env PATH="$shim_dir:$PATH" SUPERTEAM_TEST_ROOT="$parent" \
    bash "$PROJECT" init "$parent" --task task --knowledge knowledge --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not atomically install superteam.yaml"* ]]
  [ "$(cat "$parent/unrelated.txt")" = 'keep parent content' ]
  [ -d "$child/.git" ]
  [ ! -e "$parent/.git" ]
  [ ! -e "$parent/.gitignore" ]
  [ ! -e "$parent/superteam.yaml" ]
  [ ! -e "$parent/task" ]
  [ ! -e "$parent/knowledge" ]
  [ ! -e "$parent/.superteam-project.lock" ]
  [ ! -e "$parent"/.superteam-project-stage.* ]
}

@test "repository add accepts relative absolute and tilde paths but stores canonical root-relative paths" {
  home="$BATS_TEST_TMPDIR/home"
  project="$home/projects/control"
  relative_repo="$project/services/api"
  external_repo="$home/repos/worker"
  make_configured_project "$project"
  make_git_root "$relative_repo"
  make_git_root "$external_repo"
  project="$(cd -P -- "$project" && pwd -P)"
  relative_repo="$(cd -P -- "$relative_repo" && pwd -P)"
  external_repo="$(cd -P -- "$external_repo" && pwd -P)"

  run bash "$PROJECT" repository add "$project" --id api --path services/api
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: REPOSITORY_ADD"* ]]
  [[ "$output" == *"REAL_GIT_ROOT: $relative_repo"* ]]
  [[ "$output" == *"MANIFEST_PATH: services/api"* ]]
  [[ "$output" == *"MANAGED_IGNORE: services/api"* ]]
  [ "$(wc -l < "$project/superteam.yaml" | tr -d ' ')" -eq 4 ]

  run bash "$PROJECT" repository add "$project" --id api --path "$relative_repo" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: REPOSITORY_ADDED"* ]]
  [ "$(cat "$project/superteam.yaml")" = $'version: 1\npaths:\n  task: "task"\n  knowledge: "knowledge"\nrepositories:\n  - id: "api"\n    path: "services/api"' ]

  run env HOME="$home" bash "$PROJECT" repository add "$project" --id worker --path '~/repos/worker' --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"REAL_GIT_ROOT: $external_repo"* ]]
  [[ "$output" == *"MANIFEST_PATH: ../../repos/worker"* ]]
  [[ "$(cat "$project/superteam.yaml")" == *$'  - id: "worker"\n    path: "../../repos/worker"' ]]
  [[ "$(cat "$project/superteam.yaml")" != *"$home"* ]]
  [[ "$(cat "$project/superteam.yaml")" != *'~/'* ]]
}

@test "repository add rejects invalid ids paths duplicates and Git root mismatches without changing the manifest" {
  project="$BATS_TEST_TMPDIR/repository validation/project"
  repo="$BATS_TEST_TMPDIR/repository validation/repo"
  make_configured_project "$project"
  make_git_root "$repo"
  mkdir -p "$repo/inside" "$BATS_TEST_TMPDIR/repository validation/not-git"
  project="$(cd -P -- "$project" && pwd -P)"
  repo="$(cd -P -- "$repo" && pwd -P)"
  original="$(cat "$project/superteam.yaml")"

  for invocation in \
    'root|REPO' \
    'Upper|REPO' \
    'bad/id|REPO' \
    'missing|MISSING' \
    'plain|NOT_GIT' \
    'inside|INSIDE' \
    'self|SELF'; do
    id=${invocation%%|*}
    path_key=${invocation#*|}
    case "$path_key" in
      REPO) path=$repo ;;
      MISSING) path="$BATS_TEST_TMPDIR/repository validation/missing" ;;
      NOT_GIT) path="$BATS_TEST_TMPDIR/repository validation/not-git" ;;
      INSIDE) path="$repo/inside" ;;
      SELF) path=$project ;;
    esac
    run bash "$PROJECT" repository add "$project" --id "$id" --path "$path" --apply
    [ "$status" -ne 0 ]
    [ "$(cat "$project/superteam.yaml")" = "$original" ]
  done

  run bash "$PROJECT" repository add "$project" --id api --path "$repo" --apply
  [ "$status" -eq 0 ]
  registered="$(cat "$project/superteam.yaml")"
  run bash "$PROJECT" repository add "$project" --id api --path "$repo" --apply
  [ "$status" -ne 0 ]
  [ "$(cat "$project/superteam.yaml")" = "$registered" ]
  run bash "$PROJECT" repository add "$project" --id alias --path "$repo" --apply
  [ "$status" -ne 0 ]
  [ "$(cat "$project/superteam.yaml")" = "$registered" ]
}

@test "repository remove only unbinds a nested repository and its owned ignore rule" {
  project="$BATS_TEST_TMPDIR/repository remove/project"
  repo="$project/services/api"
  make_configured_project "$project"
  make_git_root "$repo"
  printf '%s\n' '/keep-user-rule/' > "$project/.gitignore"
  chmod 0664 "$project/superteam.yaml"
  chmod 0660 "$project/.gitignore"
  manifest_mode_before="$(file_mode "$project/superteam.yaml")"
  ignore_mode_before="$(file_mode "$project/.gitignore")"
  git -C "$repo" remote add origin ../remote-placeholder
  git -C "$repo" commit --allow-empty -qm baseline
  head_before="$(git -C "$repo" rev-parse HEAD)"
  remote_before="$(git -C "$repo" remote -v)"

  run bash "$PROJECT" repository add "$project" --id api --path services/api --apply
  [ "$status" -eq 0 ]
  grep -Fqx '# superteam-managed repository: api' "$project/.gitignore"
  grep -Fqx '/services/api/' "$project/.gitignore"
  [ "$(file_mode "$project/superteam.yaml")" = "$manifest_mode_before" ]
  [ "$(file_mode "$project/.gitignore")" = "$ignore_mode_before" ]

  run bash "$PROJECT" repository remove "$project" --id api
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: REPOSITORY_REMOVE"* ]]
  [[ "$(cat "$project/superteam.yaml")" == *'id: "api"'* ]]
  run bash "$PROJECT" repository remove "$project" --id api --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: REPOSITORY_REMOVED"* ]]
  [ "$(wc -l < "$project/superteam.yaml" | tr -d ' ')" -eq 4 ]
  [ "$(cat "$project/.gitignore")" = '/keep-user-rule/' ]
  [ "$(file_mode "$project/superteam.yaml")" = "$manifest_mode_before" ]
  [ "$(file_mode "$project/.gitignore")" = "$ignore_mode_before" ]
  [ -d "$repo/.git" ]
  [ "$(git -C "$repo" rev-parse HEAD)" = "$head_before" ]
  [ "$(git -C "$repo" remote -v)" = "$remote_before" ]

  repo_without_eof="$project/services/worker"
  make_git_root "$repo_without_eof"
  printf '%s' '/keep-without-eof/' > "$project/.gitignore"
  ignore_before="$(cksum < "$project/.gitignore")"
  run bash "$PROJECT" repository add "$project" --id worker --path services/worker --apply
  [ "$status" -eq 0 ]
  run bash "$PROJECT" repository remove "$project" --id worker --apply
  [ "$status" -eq 0 ]
  [ "$(cksum < "$project/.gitignore")" = "$ignore_before" ]

  empty_repo="$project/services/empty"
  make_git_root "$empty_repo"
  : > "$project/.gitignore"
  chmod 0660 "$project/.gitignore"
  empty_mode_before="$(file_mode "$project/.gitignore")"
  run bash "$PROJECT" repository add "$project" --id empty --path services/empty --apply
  [ "$status" -eq 0 ]
  run bash "$PROJECT" repository remove "$project" --id empty --apply
  [ "$status" -eq 0 ]
  [ -f "$project/.gitignore" ]
  [ ! -s "$project/.gitignore" ]
  [ "$(file_mode "$project/.gitignore")" = "$empty_mode_before" ]
}

@test "repository add preserves submodules and pre-existing ignore rules" {
  project="$BATS_TEST_TMPDIR/repository topology/project"
  origin="$BATS_TEST_TMPDIR/repository topology/origin"
  ignored="$project/vendor/ignored"
  make_configured_project "$project"
  make_git_root "$origin"
  git -C "$origin" commit --allow-empty -qm baseline
  git -C "$project" add task knowledge superteam.yaml
  git -C "$project" commit -qm project
  git -c protocol.file.allow=always -C "$project" submodule add -q "$origin" deps/lib
  make_git_root "$ignored"
  printf '%s\n' '/vendor/' > "$project/.gitignore"
  modules_before="$(cat "$project/.gitmodules")"
  gitlink_before="$(git -C "$project" ls-files --stage -- deps/lib)"

  run bash "$PROJECT" repository add "$project" --id lib --path deps/lib --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOPOLOGY: SUBMODULE"* ]]
  [ "$(cat "$project/.gitmodules")" = "$modules_before" ]
  [ "$(git -C "$project" ls-files --stage -- deps/lib)" = "$gitlink_before" ]
  [ "$(cat "$project/.gitignore")" = '/vendor/' ]

  run bash "$PROJECT" repository add "$project" --id ignored --path vendor/ignored --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"IGNORE: EXISTING"* ]]
  [ "$(cat "$project/.gitignore")" = '/vendor/' ]
}

@test "repository status and doctor report root first and expose member anomalies in manifest order" {
  project="$BATS_TEST_TMPDIR/repository status/project"
  dirty="$BATS_TEST_TMPDIR/repository status/dirty"
  detached="$BATS_TEST_TMPDIR/repository status/detached"
  missing="$BATS_TEST_TMPDIR/repository status/missing"
  mismatch="$BATS_TEST_TMPDIR/repository status/mismatch"
  make_configured_project "$project"
  for repo in "$dirty" "$detached" "$missing" "$mismatch"; do
    make_git_root "$repo"
    git -C "$repo" commit --allow-empty -qm baseline
  done
  for entry in "dirty:$dirty" "detached:$detached" "missing:$missing" "mismatch:$mismatch"; do
    id=${entry%%:*}
    path=${entry#*:}
    run bash "$PROJECT" repository add "$project" --id "$id" --path "$path" --apply
    [ "$status" -eq 0 ]
  done
  printf '%s\n' changed > "$dirty/changed"
  git -C "$detached" checkout -q --detach HEAD
  mv "$missing" "$missing-relocated"
  mv "$mismatch/.git" "$mismatch-git"

  for command in status doctor; do
    run bash "$PROJECT" "$command" "$project"
    [ "$status" -eq 0 ]
    root_line="$(printf '%s\n' "$output" | grep -n '^REPOSITORY: root$' | cut -d: -f1)"
    dirty_line="$(printf '%s\n' "$output" | grep -n '^REPOSITORY: dirty$' | cut -d: -f1)"
    detached_line="$(printf '%s\n' "$output" | grep -n '^REPOSITORY: detached$' | cut -d: -f1)"
    missing_line="$(printf '%s\n' "$output" | grep -n '^REPOSITORY: missing$' | cut -d: -f1)"
    mismatch_line="$(printf '%s\n' "$output" | grep -n '^REPOSITORY: mismatch$' | cut -d: -f1)"
    [ "$root_line" -lt "$dirty_line" ]
    [ "$dirty_line" -lt "$detached_line" ]
    [ "$detached_line" -lt "$missing_line" ]
    [ "$missing_line" -lt "$mismatch_line" ]
    [[ "$output" == *$'REPOSITORY: dirty\n'**$'WORKTREE: DIRTY'* ]]
    [[ "$output" == *$'REPOSITORY: detached\n'**$'BRANCH: DETACHED'* ]]
    [[ "$output" == *$'REPOSITORY: missing\n'**$'GIT_ROOT: MISSING'* ]]
    [[ "$output" == *$'REPOSITORY: mismatch\n'**$'GIT_ROOT: MISMATCH'* ]]
    [[ "$output" == *'UPSTREAM: NONE'* ]]
  done

  mv "$mismatch-git" "$mismatch/.git"
  run bash "$PROJECT" repository remove "$project" --id missing --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"REAL_GIT_ROOT: MISSING"* ]]
  [[ "$output" == *"RESULT: REPOSITORY_REMOVED"* ]]
  [[ "$(cat "$project/superteam.yaml")" != *'id: "missing"'* ]]
  [ -d "$missing-relocated/.git" ]
}

@test "repository writes roll back the manifest and managed ignore file after a normal install failure" {
  project="$BATS_TEST_TMPDIR/repository rollback/project"
  repo="$project/services/api"
  make_configured_project "$project"
  make_git_root "$repo"
  printf '%s\n' '/keep-user-rule/' > "$project/.gitignore"
  chmod 0664 "$project/superteam.yaml"
  chmod 0660 "$project/.gitignore"
  original_manifest="$(cat "$project/superteam.yaml")"
  original_ignore="$(cat "$project/.gitignore")"
  manifest_mode_before="$(file_mode "$project/superteam.yaml")"
  ignore_mode_before="$(file_mode "$project/.gitignore")"
  shim_dir="$BATS_TEST_TMPDIR/repository rollback/bin"
  mkdir -p "$shim_dir"
  printf '%s\n' '#!/usr/bin/env bash' \
    'destination=""; for argument in "$@"; do destination=$argument; done' \
    'case "$destination" in */superteam.yaml) exit 75 ;; esac' \
    'exec /bin/mv "$@"' > "$shim_dir/mv"
  chmod +x "$shim_dir/mv"

  run env PATH="$shim_dir:$PATH" bash "$PROJECT" repository add "$project" --id api --path services/api --apply
  [ "$status" -ne 0 ]
  [ "$(cat "$project/superteam.yaml")" = "$original_manifest" ]
  [ "$(cat "$project/.gitignore")" = "$original_ignore" ]
  [ "$(file_mode "$project/superteam.yaml")" = "$manifest_mode_before" ]
  [ "$(file_mode "$project/.gitignore")" = "$ignore_mode_before" ]
  [ ! -e "$project/.superteam-project.lock" ]
  [ -d "$repo/.git" ]
}

@test "repository management ignores caller Git environment pollution" {
  project="$BATS_TEST_TMPDIR/repository git isolation/project"
  repo="$BATS_TEST_TMPDIR/repository git isolation/member"
  foreign="$BATS_TEST_TMPDIR/repository git isolation/foreign"
  make_configured_project "$project"
  make_git_root "$repo"
  make_git_root "$foreign"
  foreign_head_before="$(git -C "$foreign" rev-parse --git-dir)"

  run env GIT_DIR="$foreign/.git" GIT_WORK_TREE="$foreign" GIT_COMMON_DIR="$foreign/.git" \
    GIT_INDEX_FILE="$foreign/.git/index-other" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$foreign/hooks" \
    bash "$PROJECT" repository add "$project" --id member --path "$repo" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: REPOSITORY_ADDED"* ]]
  [[ "$(cat "$project/superteam.yaml")" == *'id: "member"'* ]]
  [ ! -e "$foreign/.git/index-other" ]
  [ "$(git -C "$foreign" rev-parse --git-dir)" = "$foreign_head_before" ]
}

@test "project pull processes root first then manifest members and distinguishes pulled from up-to-date" {
  root_remote="$BATS_TEST_TMPDIR/pull complete/root.git"
  project="$BATS_TEST_TMPDIR/pull complete/project"
  api_remote="$BATS_TEST_TMPDIR/pull complete/api.git"
  api="$BATS_TEST_TMPDIR/pull complete/api"
  worker_remote="$BATS_TEST_TMPDIR/pull complete/worker.git"
  worker="$BATS_TEST_TMPDIR/pull complete/worker"
  foreign="$BATS_TEST_TMPDIR/pull complete/foreign"
  mkdir -p "$BATS_TEST_TMPDIR/pull complete"
  make_remote_clone "$root_remote" "$project"
  make_remote_clone "$api_remote" "$api"
  make_remote_clone "$worker_remote" "$worker"
  make_git_root "$foreign"
  mkdir -p "$project/task" "$project/knowledge"
  printf '%s\n' \
    'version: 1' \
    'paths:' \
    '  task: "task"' \
    '  knowledge: "knowledge"' > "$project/superteam.yaml"
  bash "$PROJECT" repository add "$project" --id api --path "$api" --apply >/dev/null
  bash "$PROJECT" repository add "$project" --id worker --path "$worker" --apply >/dev/null
  commit_and_push_project "$project"

  root_before="$(git -C "$project" rev-parse HEAD)"
  api_before="$(git -C "$api" rev-parse HEAD)"
  worker_before="$(git -C "$worker" rev-parse HEAD)"
  advance_remote "$root_remote" "$BATS_TEST_TMPDIR/pull complete/root-updater" root-update
  advance_remote "$worker_remote" "$BATS_TEST_TMPDIR/pull complete/worker-updater" worker-update
  root_expected="$(git --git-dir="$root_remote" rev-parse HEAD)"
  worker_expected="$(git --git-dir="$worker_remote" rev-parse HEAD)"

  run env GIT_DIR="$foreign/.git" GIT_WORK_TREE="$foreign" \
    GIT_INDEX_FILE="$foreign/.git/index-polluted" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$foreign/hooks" \
    bash "$PROJECT" pull "$project"
  [ "$status" -eq 0 ]
  root_line="$(printf '%s\n' "$output" | grep -n '^REPOSITORY: root$' | cut -d: -f1)"
  api_line="$(printf '%s\n' "$output" | grep -n '^REPOSITORY: api$' | cut -d: -f1)"
  worker_line="$(printf '%s\n' "$output" | grep -n '^REPOSITORY: worker$' | cut -d: -f1)"
  [ "$root_line" -lt "$api_line" ]
  [ "$api_line" -lt "$worker_line" ]
  root_block="$(repository_result_block root)"
  api_block="$(repository_result_block api)"
  worker_block="$(repository_result_block worker)"
  [[ "$root_block" == *$'REPOSITORY_PATH: .\n'**$'PULL_STATUS: pulled\nBEFORE: '"$root_before"$'\nAFTER: '"$root_expected"$'\nREASON: FAST_FORWARD'* ]]
  [[ "$api_block" == *$'PULL_STATUS: up-to-date\nBEFORE: '"$api_before"$'\nAFTER: '"$api_before"$'\nREASON: ALREADY_UP_TO_DATE'* ]]
  [[ "$worker_block" == *$'PULL_STATUS: pulled\nBEFORE: '"$worker_before"$'\nAFTER: '"$worker_expected"$'\nREASON: FAST_FORWARD'* ]]
  [[ "$output" == *$'PULLED: 2\nUP_TO_DATE: 1\nSKIPPED: 0\nFAILED: 0\nRESULT: COMPLETE'* ]]
  [ "$(git -C "$project" rev-parse HEAD)" = "$root_expected" ]
  [ "$(git -C "$worker" rev-parse HEAD)" = "$worker_expected" ]
  [ "$(git -C "$api" rev-parse HEAD)" = "$api_before" ]
  [ ! -e "$foreign/.git/index-polluted" ]
}

@test "project pull skips unsafe repositories, isolates a failed fast-forward, and continues in order" {
  base="$BATS_TEST_TMPDIR/pull partial"
  root_remote="$base/root.git"
  project="$base/project"
  mkdir -p "$base"
  make_remote_clone "$root_remote" "$project"
  mkdir -p "$project/task" "$project/knowledge"
  printf '%s\n' \
    'version: 1' \
    'paths:' \
    '  task: "task"' \
    '  knowledge: "knowledge"' > "$project/superteam.yaml"

  for id in dirty detached diverged missing mismatch tail; do
    make_remote_clone "$base/$id.git" "$base/$id"
  done
  make_git_root "$base/no-upstream"
  git -C "$base/no-upstream" config core.hooksPath /dev/null
  git -C "$base/no-upstream" commit --allow-empty -qm baseline
  for id in dirty detached no-upstream diverged missing mismatch tail; do
    bash "$PROJECT" repository add "$project" --id "$id" --path "$base/$id" --apply >/dev/null
  done
  commit_and_push_project "$project"

  printf '%s\n' dirty > "$base/dirty/untracked.txt"
  git -C "$base/dirty" config status.showUntrackedFiles no
  git -C "$base/detached" checkout -q --detach HEAD
  printf '%s\n' local > "$base/diverged/local.txt"
  git -C "$base/diverged" add -- local.txt
  git -C "$base/diverged" commit -qm local
  diverged_before="$(git -C "$base/diverged" rev-parse HEAD)"
  advance_remote "$base/diverged.git" "$base/diverged-updater" remote
  mv "$base/missing" "$base/missing-relocated"
  mv "$base/mismatch/.git" "$base/mismatch-git"
  tail_before="$(git -C "$base/tail" rev-parse HEAD)"
  advance_remote "$base/tail.git" "$base/tail-updater" tail-update
  tail_expected="$(git --git-dir="$base/tail.git" rev-parse HEAD)"
  printf '%s\n' root-dirty > "$project/root-untracked.txt"
  git -C "$project" config status.showUntrackedFiles no

  run bash "$PROJECT" pull "$project"
  [ "$status" -eq 2 ]
  root_block="$(repository_result_block root)"
  dirty_block="$(repository_result_block dirty)"
  detached_block="$(repository_result_block detached)"
  no_upstream_block="$(repository_result_block no-upstream)"
  diverged_block="$(repository_result_block diverged)"
  missing_block="$(repository_result_block missing)"
  mismatch_block="$(repository_result_block mismatch)"
  tail_block="$(repository_result_block tail)"
  [[ "$root_block" == *$'PULL_STATUS: skipped\n'**$'REASON: DIRTY_WORKTREE'* ]]
  [[ "$dirty_block" == *$'PULL_STATUS: skipped\n'**$'REASON: DIRTY_WORKTREE'* ]]
  [[ "$detached_block" == *$'PULL_STATUS: skipped\n'**$'REASON: DETACHED_HEAD'* ]]
  [[ "$no_upstream_block" == *$'PULL_STATUS: skipped\n'**$'REASON: NO_UPSTREAM'* ]]
  [[ "$diverged_block" == *$'PULL_STATUS: failed\nBEFORE: '"$diverged_before"$'\nAFTER: '"$diverged_before"$'\nREASON: FAST_FORWARD_PULL_FAILED'* ]]
  [[ "$missing_block" == *$'PULL_STATUS: skipped\nBEFORE: UNAVAILABLE\nAFTER: UNAVAILABLE\nREASON: MISSING_PATH'* ]]
  [[ "$mismatch_block" == *$'PULL_STATUS: skipped\nBEFORE: UNAVAILABLE\nAFTER: UNAVAILABLE\nREASON: GIT_ROOT_MISMATCH'* ]]
  [[ "$tail_block" == *$'PULL_STATUS: pulled\nBEFORE: '"$tail_before"$'\nAFTER: '"$tail_expected"$'\nREASON: FAST_FORWARD'* ]]
  [[ "$output" == *$'PULLED: 1\nUP_TO_DATE: 0\nSKIPPED: 6\nFAILED: 1\nRESULT: PARTIAL'* ]]
  [ "$(git -C "$base/diverged" rev-parse HEAD)" = "$diverged_before" ]
  [ "$(git -C "$base/tail" rev-parse HEAD)" = "$tail_expected" ]
  [ -d "$base/missing-relocated/.git" ]
  [ -d "$base/mismatch-git" ]
}

@test "project pull detects submodule dirtiness hidden by local Git config" {
  base="$BATS_TEST_TMPDIR/pull hidden submodule"
  root_remote="$base/root.git"
  project="$base/project"
  sub_remote="$base/sub.git"
  sub_source="$base/sub-source"
  mkdir -p "$base"
  make_remote_clone "$root_remote" "$project"
  make_remote_clone "$sub_remote" "$sub_source"
  mkdir -p "$project/task" "$project/knowledge"
  printf '%s\n' \
    'version: 1' \
    'paths:' \
    '  task: "task"' \
    '  knowledge: "knowledge"' > "$project/superteam.yaml"
  git -c protocol.file.allow=always -C "$project" submodule add -q "$sub_remote" deps/lib
  commit_and_push_project "$project"
  root_before="$(git -C "$project" rev-parse HEAD)"
  printf '%s\n' hidden-dirty > "$project/deps/lib/untracked.txt"
  git -C "$project" config diff.ignoreSubmodules all
  [ -z "$(git -C "$project" status --porcelain)" ]
  [ -n "$(git -C "$project" status --porcelain --untracked-files=all --ignore-submodules=none)" ]

  run bash "$PROJECT" pull "$project"
  [ "$status" -eq 2 ]
  root_block="$(repository_result_block root)"
  [[ "$root_block" == *$'PULL_STATUS: skipped\nBEFORE: '"$root_before"$'\nAFTER: '"$root_before"$'\nREASON: DIRTY_WORKTREE'* ]]
  [ "$(git -C "$project" rev-parse HEAD)" = "$root_before" ]
  [ -f "$project/deps/lib/untracked.txt" ]
}

@test "project pull detects untracked files hidden by local Git config" {
  base="$BATS_TEST_TMPDIR/pull hidden untracked"
  root_remote="$base/root.git"
  project="$base/project"
  mkdir -p "$base"
  make_remote_clone "$root_remote" "$project"
  mkdir -p "$project/task" "$project/knowledge"
  printf '%s\n' \
    'version: 1' \
    'paths:' \
    '  task: "task"' \
    '  knowledge: "knowledge"' > "$project/superteam.yaml"
  commit_and_push_project "$project"
  project="$(cd -P -- "$project" && pwd -P)"
  root_before="$(git -C "$project" rev-parse HEAD)"
  printf '%s\n' hidden-dirty > "$project/untracked.txt"
  git -C "$project" config status.showUntrackedFiles no
  [ -z "$(git -C "$project" status --porcelain)" ]
  [ -n "$(git -C "$project" status --porcelain --untracked-files=all --ignore-submodules=none)" ]

  run bash "$PROJECT" pull "$project"
  [ "$status" -eq 2 ]
  root_block="$(repository_result_block root)"
  [[ "$root_block" == *$'PULL_STATUS: skipped\nBEFORE: '"$root_before"$'\nAFTER: '"$root_before"$'\nREASON: DIRTY_WORKTREE'* ]]
  [ "$(git -C "$project" rev-parse HEAD)" = "$root_before" ]
  [ -f "$project/untracked.txt" ]
}

@test "project pull fails closed when worktree status cannot be inspected" {
  base="$BATS_TEST_TMPDIR/pull status failure"
  root_remote="$base/root.git"
  project="$base/project"
  shim_dir="$base/bin"
  mkdir -p "$base" "$shim_dir"
  make_remote_clone "$root_remote" "$project"
  mkdir -p "$project/task" "$project/knowledge"
  printf '%s\n' \
    'version: 1' \
    'paths:' \
    '  task: "task"' \
    '  knowledge: "knowledge"' > "$project/superteam.yaml"
  commit_and_push_project "$project"
  project="$(cd -P -- "$project" && pwd -P)"
  root_before="$(git -C "$project" rev-parse HEAD)"
  advance_remote "$root_remote" "$base/root-updater" root-update
  printf '%s\n' '#!/usr/bin/env bash' \
    'for argument in "$@"; do' \
    '  [ "$argument" != status ] || exit 75' \
    'done' \
    'exec "$SUPERTEAM_TEST_REAL_GIT" "$@"' > "$shim_dir/git"
  chmod +x "$shim_dir/git"

  run env PATH="$shim_dir:$PATH" SUPERTEAM_TEST_ROOT="$project" \
    SUPERTEAM_TEST_REAL_GIT="$(command -v git)" bash "$PROJECT" pull "$project"
  [ "$status" -eq 2 ]
  root_block="$(repository_result_block root)"
  [[ "$root_block" == *$'PULL_STATUS: skipped\nBEFORE: '"$root_before"$'\nAFTER: '"$root_before"$'\nREASON: WORKTREE_STATUS_UNAVAILABLE'* ]]
  [ "$(git -C "$project" rev-parse HEAD)" = "$root_before" ]
}

@test "project pull does not recurse into submodules even when local Git config enables recursion" {
  base="$BATS_TEST_TMPDIR/pull submodule"
  root_remote="$base/root.git"
  project="$base/project"
  sub_remote="$base/sub.git"
  sub_source="$base/sub-source"
  mkdir -p "$base"
  make_remote_clone "$root_remote" "$project"
  make_remote_clone "$sub_remote" "$sub_source"
  mkdir -p "$project/task" "$project/knowledge"
  printf '%s\n' \
    'version: 1' \
    'paths:' \
    '  task: "task"' \
    '  knowledge: "knowledge"' > "$project/superteam.yaml"
  git -c protocol.file.allow=always -C "$project" submodule add -q "$sub_remote" deps/lib
  commit_and_push_project "$project"
  sub_before="$(git -C "$project/deps/lib" rev-parse HEAD)"

  advance_remote "$sub_remote" "$base/sub-updater" sub-update
  root_updater="$base/root-updater"
  git -c core.hooksPath=/dev/null clone -q "$root_remote" "$root_updater"
  git -C "$root_updater" config user.name "Fixture Contributor"
  git -C "$root_updater" config user.email "fixture@invalid"
  git -C "$root_updater" config core.hooksPath /dev/null
  git -c protocol.file.allow=always -c core.hooksPath=/dev/null -C "$root_updater" submodule update -q --init
  git -C "$root_updater/deps/lib" config core.hooksPath /dev/null
  git -C "$root_updater/deps/lib" fetch -q origin
  git -C "$root_updater/deps/lib" checkout -q origin/HEAD
  git -C "$root_updater" add -- deps/lib
  git -C "$root_updater" commit -qm 'advance submodule gitlink'
  git -C "$root_updater" push -q
  root_expected="$(git --git-dir="$root_remote" rev-parse HEAD)"
  git -C "$project" config submodule.recurse true

  run bash "$PROJECT" pull "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *'PULL_STATUS: pulled'* ]]
  [[ "$output" == *'RESULT: COMPLETE'* ]]
  [ "$(git -C "$project" rev-parse HEAD)" = "$root_expected" ]
  [ "$(git -C "$project/deps/lib" rev-parse HEAD)" = "$sub_before" ]
}

@test "project pull reports FAILED and exits one when a Project cannot be parsed" {
  uninitialized="$BATS_TEST_TMPDIR/pull failed/uninitialized"
  malformed="$BATS_TEST_TMPDIR/pull failed/malformed"
  mkdir -p "$uninitialized"
  make_configured_project "$malformed"
  printf '%s\n' 'version: 1' 'paths:' '  task: task' '  knowledge: "knowledge"' > "$malformed/superteam.yaml"

  for target in "$uninitialized" "$malformed"; do
    run bash "$PROJECT" pull "$target"
    [ "$status" -eq 1 ]
    [[ "$output" == *'RESULT: FAILED'* ]]
    [[ "$output" == *'PULLED: 0'* ]]
    [[ "$output" == *'UP_TO_DATE: 0'* ]]
    [[ "$output" == *'SKIPPED: 0'* ]]
    [[ "$output" == *'FAILED: 0'* ]]
  done
}
