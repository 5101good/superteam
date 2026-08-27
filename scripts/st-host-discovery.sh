#!/usr/bin/env bash

set -u

LC_ALL=C
export LC_ALL

release_root=${1:-}
host_work_directory=''
temporary_root=${TMPDIR:-/tmp}

fail() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [ -n "$host_work_directory" ] && [ -d "$host_work_directory" ]; then
    case "$host_work_directory" in
      "$temporary_root"/superteam-host-discovery.*)
        rm -rf -- "$host_work_directory"
        ;;
    esac
  fi
}

command_version() {
  version_command=$1
  version_output_file=$2
  version_value=''

  "$version_command" --version > "$version_output_file" 2>&1 || \
    fail "cannot read Host tool version: $version_command"
  version_value=$(sed -n '1p' "$version_output_file") || \
    fail "cannot parse Host tool version: $version_command"
  [ -n "$version_value" ] || \
    fail "Host tool returned an empty version: $version_command"
  printf '%s\n' "$version_value"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required Host tool is unavailable: $1"
}

skill_names_from_tree() {
  tree_root=$1
  output_file=$2

  : > "$output_file"
  for skill_directory in "$tree_root"/skills/*; do
    [ -d "$skill_directory" ] || continue
    skill_name=${skill_directory##*/}
    [ -f "$skill_directory/SKILL.md" ] || \
      fail "Skill is missing SKILL.md: $skill_name"
    grep -Fqx "name: $skill_name" "$skill_directory/SKILL.md" || \
      fail "Skill frontmatter name does not match its directory: $skill_name"
    case "$skill_name" in
      *[!a-z0-9-]*|'') fail "Skill name cannot form a Host selector: $skill_name" ;;
    esac
    printf '%s\n' "$skill_name" >> "$output_file"
  done
  LC_ALL=C sort -u "$output_file" -o "$output_file"
  [ -s "$output_file" ] || fail 'release contains no Skills'
}

selector_set() {
  selector_prefix=$1
  names_file=$2
  output_file=$3

  : > "$output_file"
  while IFS= read -r skill_name; do
    [ -n "$skill_name" ] || continue
    printf '%s%s\n' "$selector_prefix" "$skill_name" >> "$output_file"
  done < "$names_file"
}

validate_selector_set() {
  selector_pattern=$1
  selectors_file=$2
  names_file=$3
  selector_count=0

  while IFS= read -r selector; do
    [ -n "$selector" ] || continue
    printf '%s\n' "$selector" | grep -Eq "$selector_pattern" || \
      fail "invalid namespaced selector syntax: $selector"
    selector_count=$((selector_count + 1))
  done < "$selectors_file"

  skill_count=$(wc -l < "$names_file" | tr -d ' ')
  [ "$selector_count" -eq "$skill_count" ] || \
    fail 'selector set does not cover every discovered Skill'
}

qoder_plugin_skill_names() {
  plugin_id=$1

  awk -F '"' -v wanted_id="$plugin_id" '
    $2 == "id" {
      if (in_plugin) {
        exit 1
      }
      if ($4 == wanted_id) {
        in_plugin = 1
        found_plugin = 1
      }
      next
    }
    in_plugin && $2 == "resources" {
      in_resources = 1
      found_resources = 1
      next
    }
    in_resources && $2 == "skills" && index($0, "[]") {
      found_skills = 1
      exit
    }
    in_resources && $2 == "skills" {
      in_skills = 1
      found_skills = 1
      next
    }
    in_skills && /^      \][[:space:]]*,?[[:space:]]*$/ {
      exit
    }
    in_skills && $2 == "name" {
      print $4
    }
    in_plugin && /^  \}[[:space:]]*,?[[:space:]]*$/ {
      exit 1
    }
    END {
      if (!found_plugin || !found_resources || !found_skills) {
        exit 1
      }
    }
  '
}

[ -n "$release_root" ] || fail 'usage: st-host-discovery.sh <release-root>'
[ -d "$release_root" ] || fail 'release root does not exist'
release_root=$(cd -P -- "$release_root" 2>/dev/null && pwd -P) || \
  fail 'release root cannot be resolved'
[ -d "$release_root/skills" ] || fail 'release root has no skills directory'

require_command codex
require_command claude
require_command qodercli
require_command cmp
require_command mktemp

[ -d "$temporary_root" ] || fail 'temporary directory root does not exist'
temporary_root=$(cd -P -- "$temporary_root" 2>/dev/null && pwd -P) || \
  fail 'temporary directory root cannot be resolved'
host_work_directory=$(mktemp -d "$temporary_root/superteam-host-discovery.XXXXXX") || \
  fail 'cannot create isolated Host work directory'
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$host_work_directory/home" "$host_work_directory/codex-home" \
  "$host_work_directory/claude-config"

codex_version=$(command_version codex "$host_work_directory/codex-version.txt") || exit 1
claude_version=$(command_version claude "$host_work_directory/claude-version.txt") || exit 1
qoder_version=$(command_version qodercli "$host_work_directory/qoder-version.txt") || exit 1

expected_names="$host_work_directory/expected-skills.txt"
skill_names_from_tree "$release_root" "$expected_names"
skill_count=$(wc -l < "$expected_names" | tr -d ' ')

codex_marketplace="$host_work_directory/codex-marketplace.json"
codex_install="$host_work_directory/codex-install.json"
codex_list="$host_work_directory/codex-list.json"
env HOME="$host_work_directory/home" CODEX_HOME="$host_work_directory/codex-home" \
  codex plugin marketplace add "$release_root" --json > "$codex_marketplace" || \
  fail 'Codex local marketplace installer rejected the release bundle'
env HOME="$host_work_directory/home" CODEX_HOME="$host_work_directory/codex-home" \
  codex plugin add superteam@superteam --json > "$codex_install" || \
  fail 'Codex local plugin installer rejected the release bundle'
env HOME="$host_work_directory/home" CODEX_HOME="$host_work_directory/codex-home" \
  codex plugin list --marketplace superteam --json > "$codex_list" || \
  fail 'Codex local registry cannot list the installed plugin'
grep -Fq '"pluginId": "superteam@superteam"' \
  "$codex_list" || fail 'Codex registry did not report superteam@superteam'
codex_installed_path=$(awk -F '"' '$2 == "installedPath" { print $4 }' \
  "$codex_install")
[ -n "$codex_installed_path" ] && [ -d "$codex_installed_path/skills" ] || \
  fail 'Codex installer did not return a readable installed Skill tree'
codex_names="$host_work_directory/codex-skills.txt"
skill_names_from_tree "$codex_installed_path" "$codex_names"
cmp "$expected_names" "$codex_names" >/dev/null || \
  fail 'Codex installed Skill set does not match the release bundle'
while IFS= read -r skill_name; do
  cmp "$release_root/skills/$skill_name/SKILL.md" \
    "$codex_installed_path/skills/$skill_name/SKILL.md" >/dev/null || \
    fail "Codex installer changed Skill content: $skill_name"
  cmp "$release_root/skills/$skill_name/agents/openai.yaml" \
    "$codex_installed_path/skills/$skill_name/agents/openai.yaml" >/dev/null || \
    fail "Codex installer changed Skill metadata: $skill_name"
done < "$expected_names"
codex_selectors="$host_work_directory/codex-selectors.txt"
selector_set '$superteam:' "$codex_names" "$codex_selectors"
validate_selector_set '^[$]superteam:[a-z0-9][a-z0-9-]*$' \
  "$codex_selectors" "$codex_names"

env HOME="$host_work_directory/home" \
  CLAUDE_CONFIG_DIR="$host_work_directory/claude-config" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
  claude plugin validate "$release_root" \
  > "$host_work_directory/claude-validate.txt" || \
  fail 'Claude Code offline validator rejected the release bundle'
claude_names="$host_work_directory/claude-skills.txt"
skill_names_from_tree "$release_root" "$claude_names"
cmp "$expected_names" "$claude_names" >/dev/null || \
  fail 'Claude Code validated Skill set does not match the release bundle'
claude_selectors="$host_work_directory/claude-selectors.txt"
selector_set '/superteam:' "$claude_names" "$claude_selectors"
validate_selector_set '^/superteam:[a-z0-9][a-z0-9-]*$' \
  "$claude_selectors" "$claude_names"

env HOME="$host_work_directory/home" qodercli plugin validate "$release_root" \
  > "$host_work_directory/qoder-validate.txt" || \
  fail 'Qoder CLI offline validator rejected the release bundle'
qoder_registry="$host_work_directory/qoder-registry.json"
env HOME="$host_work_directory/home" \
  qodercli plugin list --json --plugin-dir "$release_root" > "$qoder_registry" || \
  fail 'Qoder CLI registry cannot enumerate the release bundle'
qoder_names="$host_work_directory/qoder-skills.txt"
qoder_plugin_skill_names superteam@flag < "$qoder_registry" | \
  LC_ALL=C sort -u > "$qoder_names" || \
  fail 'Qoder CLI registry did not expose superteam@flag Skills'
cmp "$expected_names" "$qoder_names" >/dev/null || \
  fail 'Qoder CLI registry Skill set does not match the release bundle'
qoder_selectors="$host_work_directory/qoder-selectors.txt"
selector_set '/superteam:' "$qoder_names" "$qoder_selectors"
validate_selector_set '^/superteam:[a-z0-9][a-z0-9-]*$' \
  "$qoder_selectors" "$qoder_names"

printf '%s\n' \
  "HOST_CODEX_VERSION: $codex_version" \
  'HOST_CODEX_DISCOVERY: PASS' \
  'HOST_CODEX_SELECTOR_SYNTAX: PASS' \
  'HOST_CODEX_SELECTOR_SOURCE: installed Skill tree' \
  "HOST_CLAUDE_CODE_VERSION: $claude_version" \
  'HOST_CLAUDE_CODE_DISCOVERY: PASS' \
  'HOST_CLAUDE_CODE_SELECTOR_SYNTAX: PASS' \
  'HOST_CLAUDE_CODE_SELECTOR_SOURCE: validator-accepted Skill tree' \
  "HOST_QODER_CLI_VERSION: $qoder_version" \
  'HOST_QODER_CLI_DISCOVERY: PASS' \
  'HOST_QODER_CLI_SELECTOR_SYNTAX: PASS' \
  'HOST_QODER_CLI_SELECTOR_SOURCE: plugin registry' \
  "SKILL_COUNT: $skill_count" \
  'MODEL_BACKED_INVOCATION: SKIP (no credentials and no model request)' \
  'HOST_RESULT: PASS'
