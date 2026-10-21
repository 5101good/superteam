#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."

qoder_plugin_skill_names() {
  plugin_id=$1

  awk -v wanted_id="\"id\": \"$plugin_id\"" '
    /^    "id":[[:space:]]*/ {
      if (in_plugin) {
        exit 1
      }
      if (index($0, wanted_id)) {
        in_plugin = 1
        found_plugin = 1
      }
      next
    }
    in_plugin && /^    "resources":[[:space:]]*\{/ {
      in_resources = 1
      found_resources = 1
      next
    }
    in_resources && /^      "skills":[[:space:]]*\[[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ {
      found_skills = 1
      exit
    }
    in_resources && /^      "skills":[[:space:]]*\[[[:space:]]*$/ {
      in_skills = 1
      found_skills = 1
      next
    }
    in_skills && /^      \][[:space:]]*,?[[:space:]]*$/ {
      exit
    }
    in_skills && match($0, /"name":[[:space:]]*"[^"]+"/) {
      value = substr($0, RSTART, RLENGTH)
      sub(/^"name":[[:space:]]*"/, "", value)
      sub(/"$/, "", value)
      print value
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

release_pattern_is_absent() {
  release_root=$1
  pattern=$2
  local release_file

  while IFS= read -r -d '' release_file; do
    if grep -E -I -i "$pattern" "$release_file" >/dev/null; then
      return 1
    fi
  done < <(find "$release_root" -type f -print0)

  if find "$release_root" -type l -print -quit | grep -q .; then
    printf '%s\n' 'unexpected symbolic link in public runtime' >&2
    return 1
  fi
}

build_runtime_boundary_pattern() {
  RUNTIME_DENIED_PATTERN='(^|[^[:alnum:]_])(python|python3|node|deno|ruby|perl|php|lua|java|yq|jq|curl|wget|fetch|aria2c|base64|base32|base16|base85|basenc|openssl|certutil|xxd|hexdump|od|uuencode|uudecode)([^[:alnum:]_]|$)'
}

runtime_file_is_clean() {
  source_file=$1

  build_runtime_boundary_pattern
  if grep -E -I "$RUNTIME_DENIED_PATTERN" "$source_file" >/dev/null; then
    printf '%s\n' 'runtime boundary violation detected' >&2
    return 1
  fi
}

runtime_paths_are_clean() {
  local runtime_path runtime_file

  for runtime_path in "$@"; do
    while IFS= read -r -d '' runtime_file; do
      runtime_file_is_clean "$runtime_file" || return 1
    done < <(find "$runtime_path" -type f -print0)

    if find "$runtime_path" -type l -print -quit | grep -q .; then
      printf '%s\n' 'runtime boundary violation detected' >&2
      return 1
    fi
  done
}

codex_agent_metadata_is_valid() {
  metadata_file=$1

  LC_ALL=C awk '
    function fail(message) {
      printf "%s:%d: %s\n", FILENAME, FNR, message > "/dev/stderr"
      invalid = 1
    }

    /^[[:space:]]*$/ { next }

    /^[^[:space:]][a-z_]*:[[:space:]]*$/ {
      parent = $0
      sub(/:[[:space:]]*$/, "", parent)
      if (parent != "interface" && parent != "policy") {
        fail("unknown top-level field " parent)
      }
      if (seen_parent[parent]++) {
        fail("duplicate top-level field " parent)
      }
      next
    }

    /^  [a-z_]+:[[:space:]]*/ {
      field = substr($0, 3)
      sub(/:.*/, "", field)
      value = substr($0, index($0, ":") + 1)
      sub(/^[[:space:]]*/, "", value)

      if (parent == "interface" &&
          (field == "display_name" || field == "short_description" ||
           field == "default_prompt")) {
        if (value !~ /^".*"$/) {
          fail("interface." field " must be a quoted string")
        }
      } else if (parent == "policy" && field == "allow_implicit_invocation") {
        if (value != "true" && value != "false") {
          fail("policy.allow_implicit_invocation must be true or false")
        }
      } else {
        fail("field " field " is not valid under " parent)
      }

      path = parent "." field
      if (seen_field[path]++) {
        fail("duplicate field " path)
      }
      next
    }

    {
      fail("unsupported Codex agent metadata syntax")
    }

    END {
      if (!seen_parent["interface"]) {
        fail("missing interface field")
      }
      if (!seen_field["interface.display_name"]) {
        fail("missing interface.display_name")
      }
      if (!seen_field["interface.short_description"]) {
        fail("missing interface.short_description")
      }
      exit invalid
    }
  ' "$metadata_file"
}

@test "Codex agent metadata keeps known fields under their schema parents" {
  while IFS= read -r skill_dir; do
    codex_agent_metadata_is_valid "$skill_dir/agents/openai.yaml"
  done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
}

@test "three host layouts expose the current public skill set" {
  [ -f "$ROOT/.codex-plugin/plugin.json" ]
  [ -f "$ROOT/.claude-plugin/plugin.json" ]
  [ -f "$ROOT/.claude-plugin/marketplace.json" ]
  [ -f "$ROOT/.qoder-plugin/plugin.json" ]
  [ -f "$ROOT/.agents/plugins/marketplace.json" ]

  for manifest in "$ROOT/.codex-plugin/plugin.json" "$ROOT/.claude-plugin/plugin.json" \
    "$ROOT/.qoder-plugin/plugin.json"; do
    grep -q '"name": "superteam"' "$manifest"
    grep -q '"version": "1.1.0"' "$manifest"
    grep -q '"name": "Superteam Contributors"' "$manifest"
    grep -q '"skills": "./skills/"' "$manifest"
  done

  grep -q '"name": "superteam"' "$ROOT/.claude-plugin/marketplace.json"
  grep -q '"version": "1.1.0"' "$ROOT/.claude-plugin/marketplace.json"
  grep -q '"name": "Superteam Contributors"' "$ROOT/.claude-plugin/marketplace.json"
  grep -q '"name": "superteam"' "$ROOT/.agents/plugins/marketplace.json"
  grep -q '"version": "1.1.0"' "$ROOT/.agents/plugins/marketplace.json"
  grep -q '"name": "Superteam Contributors"' "$ROOT/.agents/plugins/marketplace.json"

  while IFS= read -r skill_dir; do
    skill=${skill_dir##*/}
    [ -f "$skill_dir/SKILL.md" ]
    [ -f "$skill_dir/agents/openai.yaml" ]
    grep -q "^name: $skill$" "$skill_dir/SKILL.md"
    grep -q '^  display_name:' "$skill_dir/agents/openai.yaml"
  done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  while IFS= read -r skill_dir; do
    skill=${skill_dir##*/}
    [ "$skill" = using-superteam ] && continue
    grep -Fq "\`$skill\`" "$ROOT/skills/using-superteam/SKILL.md"
  done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  if command -v qodercli >/dev/null 2>&1; then
    run qodercli plugin validate "$ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Plugin "superteam" is valid'* ]]

    run qodercli plugin list --json --plugin-dir "$ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"id": "superteam@flag"'* ]]
    expected_names="$(
      find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort |
        while IFS= read -r skill_dir; do
          printf '%s\n' "${skill_dir##*/}"
        done
    )"
    discovered_names="$(
      printf '%s\n' "$output" | qoder_plugin_skill_names superteam@flag | LC_ALL=C sort
    )"
    [ "$discovered_names" = "$expected_names" ]
  fi
}

@test "Skill invocation policy agrees between hosts" {
  while IFS= read -r skill_dir; do
    if grep -q '^disable-model-invocation: true$' "$skill_dir/SKILL.md"; then
      grep -q '^  allow_implicit_invocation: false$' "$skill_dir/agents/openai.yaml"
    else
      ! grep -q 'allow_implicit_invocation: false' "$skill_dir/agents/openai.yaml"
    fi
  done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  grep -q '^disable-model-invocation: true$' "$ROOT/skills/superteam-project/SKILL.md"
}

@test "Skill text names only bundled scripts and linked files that exist" {
  while IFS= read -r script_name; do
    [ -f "$ROOT/scripts/$script_name" ] || {
      printf 'missing bundled script: %s\n' "$script_name" >&2
      return 1
    }
  done < <(grep -rhoE 'st-[a-z-]+\.sh' "$ROOT/skills" | LC_ALL=C sort -u)

  while IFS= read -r markdown_file; do
    directory=${markdown_file%/*}
    while IFS= read -r link_target; do
      target=${link_target%%#*}
      [ -e "$directory/$target" ] || {
        printf 'broken link in %s: %s\n' "$markdown_file" "$link_target" >&2
        return 1
      }
    done < <(grep -oE '\]\([^):]+\)' "$markdown_file" | sed 's/^](//; s/)$//')
  done < <(find "$ROOT/skills" -name '*.md' -type f | LC_ALL=C sort)
}

@test "Qoder skill listing is scoped to one plugin installation" {
  qoder_fixture='[
  {
    "id": "superteam@flag",
    "resources": {
      "skills": [
        { "name": "using-superteam" }
      ]
    }
  },
  {
    "id": "superteam@older-installation",
    "resources": {
      "skills": [
        { "name": "superteam-triage" }
      ]
    }
  }
]'
  scoped_names="$(printf '%s\n' "$qoder_fixture" | qoder_plugin_skill_names superteam@flag)"
  [ "$scoped_names" = using-superteam ]

  qoder_missing_skills='[
  {
    "id": "superteam@flag",
    "resources": {}
  },
  {
    "id": "superteam@older-installation",
    "resources": {
      "skills": [
        { "name": "using-superteam" }
      ]
    }
  }
]'
  run qoder_plugin_skill_names superteam@flag <<< "$qoder_missing_skills"
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  qoder_empty_skills='[
  {
    "id": "superteam@flag",
    "resources": {
      "skills": []
    }
  },
  {
    "id": "superteam@older-installation",
    "resources": {
      "skills": [
        { "name": "using-superteam" }
      ]
    }
  }
]'
  run qoder_plugin_skill_names superteam@flag <<< "$qoder_empty_skills"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

}

@test "bundle-root handoff works from a directory with an unrelated name" {
  installed_root="$BATS_TEST_TMPDIR/local-plugin-copy"
  ln -s "$ROOT" "$installed_root"

  expected_root="$(cd "$ROOT" && pwd -P)"
  [ -d "$installed_root/skills" ]
  grep -q '"skills": "./skills/"' "$installed_root/.codex-plugin/plugin.json"
  grep -q '"skills": "./skills/"' "$installed_root/.claude-plugin/plugin.json"
  run bash "$installed_root/scripts/st-plugin-root.sh" from-script
  [ "$status" -eq 0 ]
  [ "$output" = "PLUGIN_ROOT: $expected_root" ]

  run env SUPERTEAM_PLUGIN_ROOT="$installed_root" \
    bash "$installed_root/scripts/st-plugin-root.sh" require
  [ "$status" -eq 0 ]
  [ "$output" = "PLUGIN_ROOT: $expected_root" ]

  run env SUPERTEAM_PLUGIN_ROOT= bash "$installed_root/scripts/st-plugin-root.sh" require
  [ "$status" -eq 2 ]
  [[ "$output" == *"SUPERTEAM_PLUGIN_ROOT is required"* ]]

  line_feed=$'\n'
  carriage_return=$'\r'
  for separator in "$line_feed" "$carriage_return"; do
    unsafe_bundle="$BATS_TEST_TMPDIR/bundle"$separator"link"
    ln -s "$ROOT" "$unsafe_bundle"
    link_before="$(readlink "$unsafe_bundle")"
    worktree_before="$(git -C "$ROOT" status --porcelain)"

    run env SUPERTEAM_PLUGIN_ROOT="$unsafe_bundle" \
      bash "$ROOT/scripts/st-plugin-root.sh" require
    [ "$status" -eq 2 ]
    [[ "$output" == *'ERROR: plugin root path contains an unsupported line break.'* ]]
    [[ "$output" != *"$unsafe_bundle"* ]]

    link_after="$(readlink "$unsafe_bundle")"
    worktree_after="$(git -C "$ROOT" status --porcelain)"
    [ "$link_before" = "$link_after" ]
    [ "$worktree_before" = "$worktree_after" ]
  done

}

@test "distribution scripts stay within the declared local runtime boundary" {
  run bash "$ROOT/scripts/st-project.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Git and Bash"* ]]

  run bash "$ROOT/scripts/st-plugin-root.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Git and Bash"* ]]

  runtime_paths_are_clean "$ROOT/scripts" "$ROOT/skills" "$ROOT/.codex-plugin" \
    "$ROOT/.claude-plugin" "$ROOT/.qoder-plugin" "$ROOT/.agents"
  release_pattern_is_absent "$ROOT/scripts" 'git[[:space:]]+(clone|push|remote[[:space:]]+add)'
  release_pattern_is_absent "$ROOT/skills" 'https?://|git[[:space:]]+(clone|push|remote[[:space:]]+add)'
  release_pattern_is_absent "$ROOT/.codex-plugin" 'https?://|git[[:space:]]+(clone|push|remote[[:space:]]+add)'
  release_pattern_is_absent "$ROOT/.claude-plugin" 'https?://|git[[:space:]]+(clone|push|remote[[:space:]]+add)'
  release_pattern_is_absent "$ROOT/.qoder-plugin" 'https?://|git[[:space:]]+(clone|push|remote[[:space:]]+add)'
  release_pattern_is_absent "$ROOT/.agents" 'https?://|git[[:space:]]+(clone|push|remote[[:space:]]+add)'

  runtime_root="$BATS_TEST_TMPDIR/runtime-boundary"
  mkdir -p "$runtime_root/scripts"
  printf '%s\n' 'base64' > "$runtime_root/scripts/entry.sh"
  run runtime_paths_are_clean "$runtime_root/scripts"
  [ "$status" -eq 1 ]
  [[ "$output" == *'runtime boundary violation detected'* ]]
}
