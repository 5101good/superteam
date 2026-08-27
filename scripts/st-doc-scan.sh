#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
SNAPSHOT="$SCRIPT_DIR/st-project-snapshot.sh"
KNOWLEDGE="$SCRIPT_DIR/st-knowledge.sh"
. "$SCRIPT_DIR/lib/git.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  st-doc-scan.sh audit <repository> <base> [head] [--project <directory>]
    [--target repository|architecture|api|reference|path]
    [--knowledge-path <relative-path>]
  st-doc-scan.sh scan <repository> [head] [--project <directory>]
    [--target repository|architecture|api|reference|path]
    [--knowledge-path <relative-path>]

Output is a stable line-oriented report. COMPLETE means every changed path has
a known documentation category. INCONCLUSIVE requires manual inspection.
EOF
  exit 2
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  return 1
}

reject_control_characters() {
  case "$1" in
    *$'\n'*|*$'\r'*) fail "$2 contains an unsupported line break."; return 1 ;;
  esac
  if printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "$2 contains an unsupported control character."
    return 1
  fi
}

safe_git() {
  isolated_git "$@"
}

resolve_repository_root() {
  project_root=$(bash "$SNAPSHOT" root "$project_path") || return 1
  repository_path=$(bash "$SNAPSHOT" repository-path "$repository_id" "$project_path") || return 1
  reject_control_characters "$project_root" 'Project root' || return 1
  reject_control_characters "$repository_path" 'Repository path' || return 1
  [ -d "$project_root/$repository_path" ] || {
    fail "Repository path does not exist: $repository_id"
    return 1
  }
  repository_root=$(cd -P -- "$project_root/$repository_path" && pwd -P) || return 1
  repository_git_root=$(safe_git -C "$repository_root" rev-parse --show-toplevel 2>/dev/null) || {
    fail "Repository is not a Git root: $repository_id"
    return 1
  }
  repository_git_root=$(cd -P -- "$repository_git_root" && pwd -P) || return 1
  [ "$repository_git_root" = "$repository_root" ] || {
    fail "Repository path does not resolve to its declared Git root: $repository_id"
    return 1
  }
}

validate_revision() {
  revision_value=$1
  revision_label=$2
  reject_control_characters "$revision_value" "$revision_label" || return 2
  case "$revision_value" in
    ''|-*) fail "$revision_label is invalid."; return 2 ;;
  esac
  safe_git -C "$repository_root" rev-parse --verify --quiet "$revision_value^{commit}" >/dev/null || {
    fail "$revision_label is not a commit: $revision_value"
    return 1
  }
}

resolve_selected_target() {
  case "$selected_target" in
    '') return 0 ;;
    repository)
      selected_target_path=$(bash "$KNOWLEDGE" repository "$repository_id" "$project_path") || return $?
      ;;
    architecture|api|reference)
      selected_target_path=$(bash "$KNOWLEDGE" "$selected_target" "$project_path") || return $?
      ;;
    path)
      [ -n "$knowledge_path" ] || {
        fail '--target path requires --knowledge-path.'
        return 2
      }
      selected_target_path=$(bash "$KNOWLEDGE" path "$knowledge_path" "$project_path") || return $?
      ;;
    *)
      fail 'target must be repository, architecture, api, reference, or path.'
      return 2
      ;;
  esac
  if [ "$selected_target" != path ] && [ -n "$knowledge_path" ]; then
    fail '--knowledge-path is valid only with --target path.'
    return 2
  fi
}

emit_unborn_scan() {
  printf '%s\n' 'FORMAT: superteam-doc-impact-v1'
  printf '%s\n' "PROJECT_ROOT: $project_root"
  printf '%s\n' "REPOSITORY: $repository_id"
  printf '%s\n' "REPOSITORY_ROOT: $repository_root"
  printf '%s\n' 'BASE: NONE' 'HEAD: UNBORN'
  if [ -n "$selected_target" ]; then
    printf '%s\n' "SELECTED_TARGET: $selected_target"
    printf '%s\n' "TARGET_PATH: $selected_target_path"
  fi
  printf '%s\n' 'CHANGED_COUNT: 0'
  printf '%s\n' 'STATUS: INCONCLUSIVE' 'REASON: UNBORN_REPOSITORY'
}

classify_path() {
  changed_path=$1
  PATH_RECOGNIZED=false
  PATH_ARCHITECTURE=false
  PATH_API=false
  PATH_REFERENCE=false

  case "$changed_path" in
    *.c|*.cc|*.cpp|*.css|*.go|*.h|*.hpp|*.html|*.js|*.jsx|*.kt|*.kts|*.md|*.proto|*.rs|*.sh|*.sql|*.swift|*.ts|*.tsx|*.yaml|*.yml|*.toml|*.json|*.xml)
      PATH_RECOGNIZED=true
      ;;
  esac
  case "/$changed_path" in
    */architecture/*|*/architectures/*|*/infra/*|*/infrastructure/*|*/deploy/*|*/deployment/*|*/migrations/*|*/Dockerfile|*/docker-compose.*)
      PATH_ARCHITECTURE=true
      PATH_RECOGNIZED=true
      ;;
  esac
  case "/$changed_path" in
    */api/*|*/apis/*|*/openapi/*|*/swagger/*|*/graphql/*|*/proto/*|*/routes/*|*/controllers/*|*.proto|*/openapi.yaml|*/openapi.yml|*/openapi.json)
      PATH_API=true
      PATH_RECOGNIZED=true
      ;;
  esac
  case "/$changed_path" in
    */docs/*|*/doc/*|*/examples/*|*/reference/*|*/references/*|*/README|*/README.*|*/CHANGELOG|*/CHANGELOG.*|*/CONTRIBUTING|*/CONTRIBUTING.*|*.md|*.yaml|*.yml|*.toml|*.json|*.xml)
      PATH_REFERENCE=true
      PATH_RECOGNIZED=true
      ;;
  esac
}

mode=${1:-}
case "$mode" in audit|scan) ;; *) usage ;; esac
shift

repository_id=${1:-}
[ -n "$repository_id" ] || usage
shift

project_path=.
selected_target=''
selected_target_path=''
knowledge_path=''
positionals=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] || usage
      project_path=$2
      shift 2
      ;;
    --target)
      [ "$#" -ge 2 ] || usage
      selected_target=$2
      shift 2
      ;;
    --knowledge-path)
      [ "$#" -ge 2 ] || usage
      knowledge_path=$2
      shift 2
      ;;
    --*) usage ;;
    *)
      positionals[${#positionals[@]}]=$1
      shift
      ;;
  esac
done

resolve_repository_root || exit 1
resolve_selected_target || exit $?

case "$mode" in
  audit)
    [ "${#positionals[@]}" -ge 1 ] && [ "${#positionals[@]}" -le 2 ] || usage
    base_revision=${positionals[0]}
    head_revision=${positionals[1]:-HEAD}
    validate_revision "$base_revision" 'base revision' || exit $?
    validate_revision "$head_revision" 'head revision' || exit $?
    base_sha=$(safe_git -C "$repository_root" rev-parse "$base_revision^{commit}") || exit 1
    ;;
  scan)
    [ "${#positionals[@]}" -le 1 ] || usage
    head_revision=${positionals[0]:-HEAD}
    if [ "$head_revision" = HEAD ] && \
      ! safe_git -C "$repository_root" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null; then
      emit_unborn_scan
      exit 3
    fi
    validate_revision "$head_revision" 'head revision' || exit $?
    base_sha=NONE
    ;;
esac

head_sha=$(safe_git -C "$repository_root" rev-parse "$head_revision^{commit}") || exit 1
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/superteam-doc-scan.XXXXXX") || exit 1
raw_changes=$temporary_directory/changes
path_list=$temporary_directory/paths
trap 'rm -f -- "$raw_changes" "$path_list"; rmdir -- "$temporary_directory" 2>/dev/null || true' EXIT HUP INT TERM

case "$mode" in
  audit)
    safe_git -C "$repository_root" -c diff.orderFile=/dev/null \
      diff --no-renames --name-only -z \
      "$base_sha" "$head_sha" -- > "$raw_changes" || exit 1
    empty_reason=NO_CHANGED_PATHS
    ;;
  scan)
    safe_git -C "$repository_root" ls-tree -r --name-only -z "$head_sha" \
      > "$raw_changes" || exit 1
    empty_reason=NO_TRACKED_PATHS
    ;;
esac
: > "$path_list"
while IFS= read -r -d '' changed_path; do
  reject_control_characters "$changed_path" 'changed path' || exit 2
  [ -n "$changed_path" ] || continue
  printf '%s\n' "$changed_path" >> "$path_list"
done < "$raw_changes"

printf '%s\n' 'FORMAT: superteam-doc-impact-v1'
printf '%s\n' "PROJECT_ROOT: $project_root"
printf '%s\n' "REPOSITORY: $repository_id"
printf '%s\n' "REPOSITORY_ROOT: $repository_root"
printf '%s\n' "BASE: $base_sha"
printf '%s\n' "HEAD: $head_sha"
if [ -n "$selected_target" ]; then
  printf '%s\n' "SELECTED_TARGET: $selected_target"
  printf '%s\n' "TARGET_PATH: $selected_target_path"
fi

changed_count=0
uncertain_count=0
architecture_impact=false
api_impact=false
reference_impact=false
while IFS= read -r changed_path || [ -n "$changed_path" ]; do
  [ -n "$changed_path" ] || continue
  changed_count=$((changed_count + 1))
  printf '%s\n' "CHANGED: $changed_path"
  classify_path "$changed_path"
  [ "$PATH_ARCHITECTURE" = false ] || architecture_impact=true
  [ "$PATH_API" = false ] || api_impact=true
  [ "$PATH_REFERENCE" = false ] || reference_impact=true
  if [ "$PATH_RECOGNIZED" = false ]; then
    uncertain_count=$((uncertain_count + 1))
    printf '%s\n' "UNCERTAIN: $changed_path"
  fi
done < "$path_list"

printf '%s\n' "CHANGED_COUNT: $changed_count"
if [ "$changed_count" -gt 0 ]; then
  printf '%s\n' "IMPACT: repository:$repository_id"
fi
[ "$architecture_impact" = false ] || printf '%s\n' 'IMPACT: architecture'
[ "$api_impact" = false ] || printf '%s\n' 'IMPACT: api'
[ "$reference_impact" = false ] || printf '%s\n' 'IMPACT: reference'
if [ "$selected_target" = path ]; then
  printf '%s\n' "IMPACT: path:$knowledge_path"
fi

if [ "$changed_count" -eq 0 ]; then
  printf '%s\n' 'STATUS: INCONCLUSIVE' "REASON: $empty_reason"
  exit 3
fi
if [ "$uncertain_count" -gt 0 ]; then
  printf '%s\n' 'STATUS: INCONCLUSIVE' "REASON: UNCATEGORIZED_PATHS:$uncertain_count"
  exit 3
fi
printf '%s\n' 'STATUS: COMPLETE' 'REASON: ALL_CHANGED_PATHS_CLASSIFIED'
