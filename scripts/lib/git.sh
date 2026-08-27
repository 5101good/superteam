#!/usr/bin/env bash

# Prepare the shared sanitized Git environment. Callers decide whether the
# user's default global config is readable for their narrowly scoped query.
prepare_isolated_git_environment() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
  unset GIT_SHALLOW_FILE GIT_QUARANTINE_PATH GIT_REPLACE_REF_BASE
  unset GIT_NO_REPLACE_OBJECTS GIT_INDEX_VERSION
  unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM GIT_CONFIG_GLOBAL
  unset GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_CEILING_DIRECTORIES
  unset GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_EXTERNAL_DIFF GIT_DIFF_OPTS
  unset GIT_ATTR_SOURCE GIT_ATTR_NOSYSTEM
  unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS
  unset GIT_ICASE_PATHSPECS GIT_OPTIONAL_LOCKS
  unset GIT_PAGER GIT_EDITOR GIT_SEQUENCE_EDITOR GIT_MERGE_AUTOEDIT
  unset GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS SSH_ASKPASS
  unset GIT_PROTOCOL_FROM_USER GIT_ALLOW_PROTOCOL GIT_PROTOCOL
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
  unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
  unset GIT_TRACE GIT_TRACE_PACK_ACCESS GIT_TRACE_PACKFILE GIT_TRACE_PACKET
  unset GIT_TRACE_INDEX GIT_TRACE_OBJECT
  unset GIT_TRACE_PERFORMANCE GIT_TRACE_SETUP GIT_TRACE_SHALLOW
  unset GIT_TRACE_CURL GIT_TRACE_CURL_NO_DATA GIT_TRACE_REDACT
  unset GIT_TRACE_FSMONITOR GIT_TRACE_REFS
  unset GIT_TRACE2 GIT_TRACE2_NORMAL GIT_TRACE2_EVENT GIT_TRACE2_PERF
  unset GIT_TRACE2_BRIEF GIT_TRACE2_EVENT_BRIEF GIT_TRACE2_REDACT
  unset GIT_TRACE2_CONFIG_PARAMS GIT_TRACE2_EVENT_NESTING
  unset GIT_TRACE2_ENV_VARS GIT_TRACE2_SESSION_ID
  unset GIT_TRACE2_DST_DEBUG GIT_TRACE2_MAX_FILES
  unset GIT_TRACE2_PARENT_NAME GIT_TRACE2_PARENT_SID
  unset GIT_FLUSH GIT_REDIRECT_STDERR
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_COUNT=3
  export GIT_CONFIG_KEY_0=core.hooksPath
  export GIT_CONFIG_VALUE_0=/dev/null
  export GIT_CONFIG_KEY_1=commit.gpgSign
  export GIT_CONFIG_VALUE_1=false
  export GIT_CONFIG_KEY_2=tag.gpgSign
  export GIT_CONFIG_VALUE_2=false
}

# Run local Git operations without inheriting caller-selected repositories,
# object/index locations, pathspec modes, injected configuration, tracing,
# transports, editors, hooks, signing, or identities.  Known config is passed
# through Git's environment interface so wrappers and tests still observe the
# real subcommand as argv[1].
isolated_git() {
  (
    prepare_isolated_git_environment
    export GIT_CONFIG_GLOBAL=/dev/null
    command git "$@"
  )
}

# Read one value from Git's default global config location without accepting a
# caller-selected config file or any author/committer environment override.
# This is intentionally narrower than isolated_git and is used only when a
# command must honor the user's configured commit identity.
default_global_git_config_get() {
  (
    prepare_isolated_git_environment
    command git config --global --get "$1"
  )
}

# Classify a worktree lookup without conflating "not a repository" with a
# failed Git process. Callers inspect GIT_TOPLEVEL_STATE (ROOT or NONE) and
# GIT_TOPLEVEL after success; any other Git failure returns non-zero.
git_toplevel_state() {
  local directory=$1 output
  GIT_TOPLEVEL_STATE=ERROR
  GIT_TOPLEVEL=''
  if output=$(LC_ALL=C isolated_git -C "$directory" rev-parse --show-toplevel 2>&1); then
    [ -n "$output" ] || return 1
    GIT_TOPLEVEL_STATE=ROOT
    GIT_TOPLEVEL=$output
    return 0
  fi
  case "$output" in
    *'not a git repository'*)
      GIT_TOPLEVEL_STATE=NONE
      return 0
      ;;
  esac
  return 1
}

# Print CLEAN, DIRTY, or ERROR for one worktree.  The explicit status options
# override repository-local settings that can otherwise hide untracked files
# or submodule changes.  ERROR is also returned non-zero so a write-capable
# caller cannot accidentally treat an inspection failure as CLEAN.
git_worktree_state() {
  local repository=$1 status_output
  if ! status_output=$(isolated_git --no-optional-locks \
      -c status.showUntrackedFiles=all \
      -c diff.ignoreSubmodules=none \
      -c submodule.recurse=false \
      -C "$repository" status --porcelain=v1 \
      --untracked-files=all --ignore-submodules=none 2>/dev/null); then
    printf '%s\n' ERROR
    return 1
  fi
  if [ -n "$status_output" ]; then
    printf '%s\n' DIRTY
  else
    printf '%s\n' CLEAN
  fi
}
