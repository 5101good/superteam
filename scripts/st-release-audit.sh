#!/usr/bin/env bash

set -u

SCRIPT_DIRECTORY=$(cd "$(dirname "$0")" && pwd -P)
. "$SCRIPT_DIRECTORY/lib/git.sh"

LC_ALL=C
export LC_ALL

release_root=${1:-}

fail() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

require_file() {
  [ -f "$release_root/$1" ] || fail "missing release file: $1"
}

require_text() {
  required_file=$1
  required_text=$2
  grep -Fq "$required_text" "$release_root/$required_file" || \
    fail "release contract missing from $required_file"
}

forbid_text() {
  forbidden_file=$1
  forbidden_pattern=$2
  if grep -Eiq "$forbidden_pattern" "$release_root/$forbidden_file"; then
    fail "forbidden release value in $forbidden_file"
  fi
}

[ -n "$release_root" ] || fail 'usage: st-release-audit.sh <release-root>'
[ -d "$release_root" ] || fail 'release root does not exist'
release_root=$(cd -P -- "$release_root" 2>/dev/null && pwd -P) || \
  fail 'release root cannot be resolved'
isolated_git -C "$release_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  fail 'release root must be a Git worktree'

for release_file in \
  .codex-plugin/plugin.json \
  .claude-plugin/plugin.json \
  .claude-plugin/marketplace.json \
  .qoder-plugin/plugin.json \
  .agents/plugins/marketplace.json \
  README.md \
  README.zh-CN.md \
  .github/assets/superteam-capabilities.png \
  .github/assets/superteam-workflow.png \
  LICENSE \
  NOTICE \
  SECURITY.md \
  CONTRIBUTING.md \
  CODE_OF_CONDUCT.md \
  RELEASING.md \
  RELEASE_REPORT.md \
  scripts/st-host-discovery.sh \
  scripts/st-release-report-audit.sh \
  scripts/st-release-gate.sh \
  .github/workflows/ci.yml; do
  require_file "$release_file"
done

for metadata_file in \
  .codex-plugin/plugin.json \
  .claude-plugin/plugin.json \
  .claude-plugin/marketplace.json \
  .qoder-plugin/plugin.json \
  .agents/plugins/marketplace.json; do
  require_text "$metadata_file" '"name": "superteam"'
  require_text "$metadata_file" '"version": "1.1.0"'
  require_text "$metadata_file" '"name": "Superteam Contributors"'
  forbid_text "$metadata_file" '"(repository|homepage|issues)"[[:space:]]*:'
  forbid_text "$metadata_file" 'https?://'
done

skill_directory_count=0
for skill_directory in "$release_root"/skills/*; do
  [ -d "$skill_directory" ] || continue
  skill_directory_count=$((skill_directory_count + 1))
  skill_name=${skill_directory##*/}
  require_file "skills/$skill_name/SKILL.md"
  require_file "skills/$skill_name/agents/openai.yaml"
  require_text "skills/$skill_name/SKILL.md" "name: $skill_name"
done
[ "$skill_directory_count" -gt 0 ] || fail 'release contains no Skills'

for readme_file in README.md README.zh-CN.md; do
  for contract_marker in \
    'https://github.com/5101good/superteam' \
    'Codex' \
    'Claude Code' \
    'Qoder CLI' \
    'superteam.yaml' \
    'task' \
    'knowledge' \
    'Git' \
    'Bash' \
    'macOS' \
    'Linux' \
    'WSL' \
    'Apache-2.0' \
    'SECURITY.md' \
    "Matt Pocock's skills" \
    'obra/superpowers'; do
    require_text "$readme_file" "$contract_marker"
  done
  forbid_text "$readme_file" 'bootstrap'
done
require_text README.md '[中文文档](README.zh-CN.md)'
require_text README.zh-CN.md '[English documentation](README.md)'

require_text LICENSE 'Apache License'
require_text NOTICE 'Copyright 2026 Superteam Contributors'

for policy_file in SECURITY.md CONTRIBUTING.md CODE_OF_CONDUCT.md RELEASING.md; do
  forbid_text "$policy_file" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}'
  forbid_text "$policy_file" 'example[.]invalid'
done

if isolated_git -C "$release_root" ls-files | \
  grep -E '(^|/)(superteam-setup|setup|bootstrap|migration)(/|$)|(^|/)superteam[.]config[.]yaml$' \
  >/dev/null; then
  fail 'obsolete setup or migration path remains in the release tree'
fi

if isolated_git -C "$release_root" grep -E -I -q '/(Users|home)/' -- .; then
  fail 'personal absolute path remains in the release tree'
fi
if isolated_git -C "$release_root" grep -E -I -q 'BEGIN [A-Z ]*PRIVATE KEY' -- .; then
  fail 'private key pattern remains in the release tree'
fi
if isolated_git -C "$release_root" grep -E -I -q 'ghp_[A-Za-z0-9_]+' -- .; then
  fail 'access token pattern remains in the release tree'
fi
if isolated_git -C "$release_root" grep -E -I -q 'sk-[A-Za-z0-9_-]+' -- .; then
  fail 'service token pattern remains in the release tree'
fi
if isolated_git -C "$release_root" grep -E -I -q \
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}' -- .; then
  fail 'personal email pattern remains in the release tree'
fi

while IFS= read -r tracked_entry; do
  [ -n "$tracked_entry" ] || continue
  tracked_mode=${tracked_entry%% *}
  tracked_file=${tracked_entry#*$'\t'}
  if [ "$tracked_mode" = 120000 ]; then
    fail "release symlink is not allowed: $tracked_file"
  elif [ -s "$release_root/$tracked_file" ]; then
    binary_summary=$(isolated_git -C "$release_root" diff --no-index --numstat -- \
      /dev/null "$release_root/$tracked_file" 2>/dev/null || :)
    case "$binary_summary" in
      -$'\t'-$'\t'*)
        case "$tracked_file" in
          .github/assets/superteam-capabilities.png|.github/assets/superteam-workflow.png) ;;
          *) fail "unrecognized binary release asset: $tracked_file" ;;
        esac
        ;;
    esac
  fi
done < <(isolated_git -C "$release_root" ls-files -s)

require_text .github/workflows/ci.yml 'macos-latest'
require_text .github/workflows/ci.yml 'ubuntu-latest'
require_text .github/workflows/ci.yml '@openai/codex@0.144.5'
require_text .github/workflows/ci.yml '@anthropic-ai/claude-code@2.1.233'
require_text .github/workflows/ci.yml '@qoder-ai/qodercli@1.1.14'
require_text .github/workflows/ci.yml 'bash scripts/st-release-gate.sh .'
require_text scripts/st-release-gate.sh 'git-diff-check'
require_text scripts/st-release-gate.sh 'shell-bash-n'
require_text scripts/st-release-gate.sh 'full-bats'
require_text scripts/st-release-gate.sh 'release-audit'
require_text scripts/st-release-gate.sh 'host-discovery'
require_text scripts/st-host-discovery.sh 'codex plugin marketplace add'
require_text scripts/st-host-discovery.sh 'claude plugin validate'
require_text scripts/st-host-discovery.sh 'qodercli plugin list --json --plugin-dir'
require_text scripts/st-host-discovery.sh 'MODEL_BACKED_INVOCATION: SKIP'
require_text RELEASE_REPORT.md 'Native macOS:'
require_text RELEASE_REPORT.md 'Containerized Ubuntu 24.04:'
require_text RELEASE_REPORT.md 'Remote CI: NOT RUN'
bash "$release_root/scripts/st-release-report-audit.sh" \
  "$release_root/RELEASE_REPORT.md" || \
  fail 'release report evidence is inconsistent'

printf '%s\n' 'VERSION: 1.1.0'
printf '%s\n' 'HOSTS: Codex, Claude Code, Qoder CLI'
printf '%s\n' 'CHECKS: metadata, bilingual docs, legal files, policies, sensitive data, paths, binary assets, CI'
printf '%s\n' 'RESULT: PASS'
