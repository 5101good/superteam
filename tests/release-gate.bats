#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
HOST_DISCOVERY="$ROOT/scripts/st-host-discovery.sh"
RELEASE_GATE="$ROOT/scripts/st-release-gate.sh"
RELEASE_REPORT_AUDIT="$ROOT/scripts/st-release-report-audit.sh"

make_skill() {
  bundle=$1
  skill=$2

  mkdir -p "$bundle/skills/$skill/agents"
  printf '%s\n' '---' "name: $skill" 'description: Fixture Skill.' '---' \
    > "$bundle/skills/$skill/SKILL.md"
  printf '%s\n' 'interface:' "  display_name: \"$skill\"" \
    '  short_description: "Fixture Skill."' \
    > "$bundle/skills/$skill/agents/openai.yaml"
}

make_bundle() {
  bundle=$1
  mkdir -p "$bundle/.codex-plugin" "$bundle/.claude-plugin" \
    "$bundle/.qoder-plugin" "$bundle/.agents/plugins"
  printf '%s\n' \
    '{"name":"superteam","version":"1.0.0","skills":"./skills/"}' \
    > "$bundle/.codex-plugin/plugin.json"
  cp "$bundle/.codex-plugin/plugin.json" "$bundle/.claude-plugin/plugin.json"
  cp "$bundle/.codex-plugin/plugin.json" "$bundle/.qoder-plugin/plugin.json"
  printf '%s\n' '{"name":"superteam","version":"1.0.0"}' \
    > "$bundle/.agents/plugins/marketplace.json"
  make_skill "$bundle" alpha
  make_skill "$bundle" bravo
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$bundle" init -q
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$bundle" add .
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$bundle" -c core.hooksPath=/dev/null -c commit.gpgSign=false \
    -c user.name=Fixture -c user.email=fixture@localhost commit -qm fixture
}

make_complete_release_report() {
  report=$1

  cat > "$report" <<'REPORT'
# Fixture Release Report

- Candidate HEAD: `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` (tested source)
- Candidate tree: `bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb` (tested source)
- Native macOS: PASS
- Containerized Ubuntu 24.04: PASS
- Remote CI: NOT RUN

## Native macOS result

- Status: PASS
- Tested source candidate: `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
- Platform: macOS fixture
- Bash: 3.2 fixture
- Git: 2.fixture
- Bats: 1.fixture; 8 cases, 7 passed, 1 skipped, 0 failed
- Gate prerequisites: fixture
- Gate result: PASS
- Release audit: PASS
- Host discovery: PASS; 2 checked-in Skills matched
- Codex CLI: fixture
- Claude Code: fixture
- Qoder CLI: fixture
- model-backed invocation: SKIP

## Containerized Ubuntu 24.04 result

- Status: PASS
- Tested source candidate: `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
- Image: ubuntu fixture
- Platform: Ubuntu fixture
- Bash: 5.2 fixture
- Git: 2.fixture
- Bats: 1.fixture; 8 cases, 7 passed, 1 skipped, 0 failed
- Gate prerequisites: fixture
- Gate result: PASS
- Release audit: PASS
- Host discovery: PASS; 2 checked-in Skills matched
- Codex CLI: fixture
- Claude Code: fixture
- Qoder CLI: fixture
- model-backed invocation: SKIP

## Remote CI result

Remote CI: NOT RUN.
REPORT
}

make_host_shims() {
  shim_dir=$1
  command_log=$2

  mkdir -p "$shim_dir"
  cat > "$shim_dir/codex" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'codex %s\n' "$*" >> "$HOST_COMMAND_LOG"
case "$*" in
  '--version')
    [ "${HOST_CODEX_VERSION_FAIL:-0}" != 1 ] || exit 75
    [ "${HOST_CODEX_VERSION_EMPTY:-0}" = 1 ] || \
      printf '%s\n' 'codex-cli 0.fixture'
    ;;
  'plugin marketplace add '*' --json')
    printf '%s\n' '{"marketplaceName":"superteam","installedRoot":"fixture","alreadyAdded":false}'
    ;;
  'plugin add superteam@superteam --json')
    installed="$CODEX_HOME/plugins/cache/superteam/superteam/1.0.0"
    mkdir -p "$installed"
    cp -R "$HOST_FIXTURE_ROOT/skills" "$installed/skills"
    printf '{\n  "pluginId": "superteam@superteam",\n  "installedPath": "%s"\n}\n' "$installed"
    ;;
  'plugin list --marketplace superteam --json')
    printf '%s\n' '{' '  "installed": [' '    {' \
      '      "pluginId": "superteam@superteam",' '      "enabled": true' \
      '    }' '  ]' '}'
    ;;
  *) exit 64 ;;
esac
SH

  cat > "$shim_dir/claude" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'claude %s\n' "$*" >> "$HOST_COMMAND_LOG"
case "$*" in
  '--version') printf '%s\n' '2.fixture' ;;
  'plugin validate '*) printf '%s\n' 'Validation passed' ;;
  *) exit 64 ;;
esac
SH

  cat > "$shim_dir/qodercli" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'qodercli %s\n' "$*" >> "$HOST_COMMAND_LOG"
case "$*" in
  '--version') printf '%s\n' '1.fixture' ;;
  'plugin validate '*) printf '%s\n' 'Plugin "superteam" is valid' ;;
  'plugin list --json --plugin-dir '*)
    if [ "${HOST_QODER_INCOMPLETE:-0}" = 1 ]; then
      printf '%s\n' '[' '  {' '    "id": "superteam@flag",' \
        '    "resources": {' '      "skills": [' \
        '        {"name": "alpha"}' '      ]' '    }' '  }' ']'
    else
      printf '%s\n' '[' '  {' '    "id": "superteam@flag",' \
        '    "resources": {' '      "skills": [' \
        '        {"name": "bravo"},' '        {"name": "alpha"}' \
        '      ]' '    }' '  }' ']'
    fi
    ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$shim_dir/codex" "$shim_dir/claude" "$shim_dir/qodercli"
  : > "$command_log"
}

setup() {
  fixture_root="$BATS_TEST_TMPDIR/bundle"
  shim_dir="$BATS_TEST_TMPDIR/bin"
  command_log="$BATS_TEST_TMPDIR/host-commands.log"
  release_report_fixture="$BATS_TEST_TMPDIR/release-report.md"
  make_bundle "$fixture_root"
  make_host_shims "$shim_dir" "$command_log"
  make_complete_release_report "$release_report_fixture"
}

@test "Host gate uses each offline installer validator or registry and reports syntax without claiming invocation" {
  run env PATH="$shim_dir:/usr/bin:/bin" HOST_FIXTURE_ROOT="$fixture_root" \
    HOST_COMMAND_LOG="$command_log" bash "$HOST_DISCOVERY" "$fixture_root"

  [ "$status" -eq 0 ]
  [[ "$output" == *'HOST_CODEX_DISCOVERY: PASS'* ]]
  [[ "$output" == *'HOST_CLAUDE_CODE_DISCOVERY: PASS'* ]]
  [[ "$output" == *'HOST_QODER_CLI_DISCOVERY: PASS'* ]]
  [[ "$output" == *'HOST_CODEX_SELECTOR_SYNTAX: PASS'* ]]
  [[ "$output" == *'HOST_CLAUDE_CODE_SELECTOR_SYNTAX: PASS'* ]]
  [[ "$output" == *'HOST_QODER_CLI_SELECTOR_SYNTAX: PASS'* ]]
  [[ "$output" == *'MODEL_BACKED_INVOCATION: SKIP'* ]]
  [[ "$output" != *'INVOCATION: PASS'* ]]
  [[ "$output" == *'SKILL_COUNT: 2'* ]]

  grep -Fq 'codex plugin marketplace add' "$command_log"
  grep -Fq 'codex plugin add superteam@superteam --json' "$command_log"
  grep -Fq 'claude plugin validate' "$command_log"
  grep -Fq 'qodercli plugin validate' "$command_log"
  grep -Fq 'qodercli plugin list --json --plugin-dir' "$command_log"
}

@test "Host gate fails when a real registry omits one checked-in Skill" {
  run env PATH="$shim_dir:/usr/bin:/bin" HOST_FIXTURE_ROOT="$fixture_root" \
    HOST_COMMAND_LOG="$command_log" HOST_QODER_INCOMPLETE=1 \
    bash "$HOST_DISCOVERY" "$fixture_root"

  [ "$status" -ne 0 ]
  [[ "$output" == *'Qoder CLI registry Skill set does not match the release bundle'* ]]
  [[ "$output" != *'HOST_RESULT: PASS'* ]]
}

@test "Host gate cannot pass when a Host version command fails" {
  run env PATH="$shim_dir:/usr/bin:/bin" HOST_FIXTURE_ROOT="$fixture_root" \
    HOST_COMMAND_LOG="$command_log" HOST_CODEX_VERSION_FAIL=1 \
    bash "$HOST_DISCOVERY" "$fixture_root"

  [ "$status" -ne 0 ]
  [[ "$output" == *'cannot read Host tool version: codex'* ]]
  [[ "$output" != *'HOST_RESULT: PASS'* ]]
}

@test "Host gate cannot pass when a Host returns an empty version" {
  run env PATH="$shim_dir:/usr/bin:/bin" HOST_FIXTURE_ROOT="$fixture_root" \
    HOST_COMMAND_LOG="$command_log" HOST_CODEX_VERSION_EMPTY=1 \
    bash "$HOST_DISCOVERY" "$fixture_root"

  [ "$status" -ne 0 ]
  [[ "$output" == *'Host tool returned an empty version: codex'* ]]
  [[ "$output" != *'HOST_RESULT: PASS'* ]]
}

@test "one public release gate owns the complete local and CI check list" {
  run bash "$RELEASE_GATE" --list-checks

  [ "$status" -eq 0 ]
  [ "$output" = $'git-diff-check\nshell-bash-n\nfull-bats\nrelease-audit\nhost-discovery' ]

  grep -Fq 'bash scripts/st-release-gate.sh .' "$ROOT/.github/workflows/ci.yml"
  grep -Fq 'install -y bats lsof' "$ROOT/.github/workflows/ci.yml"
  ! grep -Fq 'bats tests' "$ROOT/.github/workflows/ci.yml"
  ! grep -Fq "find scripts -type f -name '*.sh'" "$ROOT/.github/workflows/ci.yml"
  ! grep -Fq 'bash scripts/st-release-audit.sh .' "$ROOT/.github/workflows/ci.yml"
  ! grep -Fq 'codex plugin marketplace add .' "$ROOT/.github/workflows/ci.yml"
  ! grep -Fq 'claude plugin validate .' "$ROOT/.github/workflows/ci.yml"
  ! grep -Fq 'qodercli plugin list --json --plugin-dir .' "$ROOT/.github/workflows/ci.yml"
}

@test "release evidence contract distinguishes two local platforms from remote CI" {
  for document in "$ROOT/RELEASING.md" "$ROOT/RELEASE_REPORT.md"; do
    grep -Fq 'st-release-gate.sh' "$document"
    grep -Fq 'model-backed' "$document"
    grep -Fq 'remote CI' "$document"
  done

  grep -Eq 'Native macOS: (PENDING|PASS|FAIL)' "$ROOT/RELEASE_REPORT.md"
  grep -Eq 'Containerized Ubuntu 24.04: (PENDING|PASS|FAIL)' \
    "$ROOT/RELEASE_REPORT.md"
  grep -Fq 'Remote CI: NOT RUN' "$ROOT/RELEASE_REPORT.md"
  ! grep -Fq 'Candidate HEAD:' "$ROOT/RELEASE_REPORT.md"
}

@test "release report audit accepts complete evidence for one tested candidate" {
  run bash "$RELEASE_REPORT_AUDIT" "$release_report_fixture"

  [ "$status" -eq 0 ]
  [[ "$output" == *'RELEASE_REPORT_RESULT: PASS'* ]]
}

@test "release report audit rejects a PASS platform with missing tool evidence" {
  tampered_report="$BATS_TEST_TMPDIR/missing-ubuntu-git.md"
  awk '
    /^## Containerized Ubuntu 24[.]04 result$/ { in_ubuntu = 1 }
    /^## Remote CI result$/ { in_ubuntu = 0 }
    in_ubuntu && /^- Git:/ { next }
    { print }
  ' "$release_report_fixture" > "$tampered_report"

  run bash "$RELEASE_REPORT_AUDIT" "$tampered_report"

  [ "$status" -eq 1 ]
  [[ "$output" == *'Ubuntu PASS evidence is missing field: Git'* ]]
  [[ "$output" != *'RELEASE_REPORT_RESULT: PASS'* ]]
}

@test "release report audit rejects platform evidence for another candidate" {
  tampered_report="$BATS_TEST_TMPDIR/mismatched-ubuntu-candidate.md"
  awk '
    /^## Containerized Ubuntu 24[.]04 result$/ { in_ubuntu = 1 }
    /^## Remote CI result$/ { in_ubuntu = 0 }
    in_ubuntu && /^- Tested source candidate:/ {
      print "- Tested source candidate: `0000000000000000000000000000000000000000`"
      next
    }
    { print }
  ' "$release_report_fixture" > "$tampered_report"

  run bash "$RELEASE_REPORT_AUDIT" "$tampered_report"

  [ "$status" -eq 1 ]
  [[ "$output" == *'Ubuntu tested candidate does not match Candidate HEAD'* ]]
  [[ "$output" != *'RELEASE_REPORT_RESULT: PASS'* ]]
}
