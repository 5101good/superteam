---
name: superteam-project
description: Inspect, initialize, and manage a Git-backed Superteam Project.
disable-model-invocation: true
---

# Superteam Project

Use this skill to inspect or manage a Project. A Project has one Root Repository that tracks its manifest, task assets, knowledge, and engineering policies. It may register additional existing local Git repositories.

## Read-only inspection

`inspect`, `status`, and `doctor` never write. Use the bundle-root handoff below before running a bundled command.

### Bundle-root contract

A Host integration that exposes an installed plugin root must pass that absolute directory as `SUPERTEAM_PLUGIN_ROOT`. The value is valid only when this command succeeds:

```bash
bash "$SUPERTEAM_PLUGIN_ROOT/scripts/st-plugin-root.sh" require
```

Superteam does not assume that a Host injects this variable automatically. If it is absent, do not guess a directory name or search unrelated paths; ask the user for the local plugin root and use the explicit local invocation below. The validation command exits without writing when the value is absent or invalid.

Capture the target Project path before resolving the separate bundle path. The target Project and the plugin bundle are different locations; never change to the bundle and then pass `.` as the Project target:

```bash
project_path="$(pwd -P)"
plugin_root="${SUPERTEAM_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  printf '%s\n' 'ERROR: ask for the local plugin bundle path before running doctor.' >&2
  exit 2
fi
export SUPERTEAM_PLUGIN_ROOT="$plugin_root"
bash "$plugin_root/scripts/st-plugin-root.sh" require &&
  bash "$plugin_root/scripts/st-project.sh" doctor "$project_path"
```

For direct local use when no Host handoff exists, ask the user for the absolute bundle path and assign it to `plugin_root`; do not derive it from the Project directory. Set and export `SUPERTEAM_PLUGIN_ROOT` to that same value, then use the command above. A caller may verify a known bundle path with `bash "/absolute/bundle/path/scripts/st-plugin-root.sh" from-script` before using it.

In an uninitialized directory `inspect` and `doctor` report `STATUS: UNINITIALIZED` and an initialization next step. They must not create files, initialize Git, or change the worktree.

For an initialized Project, `inspect`, `status`, and `doctor` also report `MANIFEST_TRACKING`, `TASK_TRACKING`, and `KNOWLEDGE_TRACKING` as `UNTRACKED`, `STAGED`, `UNCOMMITTED`, or `COMMITTED`. These are observations only; no read command stages or commits files.

## Project initialization and adoption

This release can initialize a root-only Project or adopt an existing Git root. Capture the target Project path before resolving the separate bundle path. Ask separately for the task and knowledge directory names; do not infer acceptance of one from the other.

Before any write, run the command without `--apply` and show its entire plan. The command is read-only in that form. The plan lists each precise effect: `CREATE_DIRECTORY` or `ADOPT_DIRECTORY`, every Superteam-owned skeleton `WRITE`, the `superteam.yaml` `WRITE`, and `INIT_GIT` when the Root Repository is new. Only add `--apply` together with that plan's printed fingerprint after the user explicitly approves the exact plan:

```bash
project_path="$(pwd -P)"
plugin_root="/absolute/path/to/the/local/bundle"
export SUPERTEAM_PLUGIN_ROOT="$plugin_root"
bash "$plugin_root/scripts/st-plugin-root.sh" require &&
  bash "$plugin_root/scripts/st-project.sh" init "$project_path" \
    --task "task" --knowledge "knowledge"
```

To apply the reviewed plan, capture its printed `PLAN_FINGERPRINT` exactly and rerun the same command with both `--apply` and `--plan-fingerprint "$plan_fingerprint"`. Never recompute or substitute the fingerprint after approval: a mismatch means the real target or relevant filesystem state changed and requires a new plan and confirmation. An empty non-Git target becomes a regular new Root Repository. A non-empty, non-Git target becomes a metadata-only Root Repository: the plan shows direct child Git roots as candidates, but none are registered automatically, and it writes an allowlist `.gitignore` that exposes only `.gitignore`, `superteam.yaml`, the confirmed task and knowledge trees, and explicitly generated policy files. If the parent already has a `.gitignore`, stop instead of overwriting it. An existing Git root is reused. Initialization writes a canonical `superteam.yaml` and minimal public README skeletons for each newly created task or knowledge directory; this first apply never stages files, creates a commit, creates a remote, or sends changes elsewhere.

After a metadata-only initialization, report that the Root Repository has no stable HEAD and ask separately whether the user wants the exact generated management assets committed locally. First show the read-only commit plan:

```bash
bash "$plugin_root/scripts/st-project.sh" init-commit "$project_path"
```

Only after the user confirms that second plan, apply it:

```bash
bash "$plugin_root/scripts/st-project.sh" init-commit "$project_path" --apply
```

The initialization commit stages only `.gitignore`, `superteam.yaml`, the confirmed task and knowledge trees, and explicitly generated policy files. It never includes child repositories or unrelated parent content, and it never creates a remote or pushes. Refusing this second step keeps all generated assets and reports `HEAD: UNBORN`. Project Init never stages or commits an existing Root Repository, even when it has no HEAD.

If a selected task or knowledge directory already exists, stop and ask whether the user wants to adopt that exact directory. Only pass the matching `--adopt-task` or `--adopt-knowledge` flag after that confirmation. A file collision, duplicate path, nested path, root escape, or symbolic-link traversal is a hard failure with no initialization write.

Use `adopt` instead of `init` when the user explicitly asks to reject a non-Git target. First show this read-only plan:

```bash
bash "$plugin_root/scripts/st-project.sh" adopt "$project_path" \
  --task "delivery" --knowledge "team-notes"
```

After the user confirms that exact plan, rerun the same parameters with its printed fingerprint:

```bash
bash "$plugin_root/scripts/st-project.sh" adopt "$project_path" \
  --task "delivery" --knowledge "team-notes" \
  --plan-fingerprint "$plan_fingerprint" --apply
```

The root-only manifest omits `repositories`; its only Repository ID is always `root`.

## Repository Set management

Register only existing local Git roots. Ask for a unique repository ID and a path; the path may be relative to the Root Repository, absolute, or begin with `~/`. First show the read-only plan:

```bash
bash "$plugin_root/scripts/st-project.sh" repository add "$project_path" \
  --id "api" --path "../api"
```

The plan shows the resolved real Git root and the canonical path that will be stored relative to the Root Repository. It never stores an absolute path, `~`, remote URL, credential, or command. It rejects `root`, invalid or duplicate IDs, missing and non-Git directories, a path inside (rather than equal to) a Git root, the Root Repository itself, and a Git root already registered under another ID. Before applying, show the full plan and obtain explicit confirmation; then repeat the same command with `--apply --plan-fingerprint "$plan_fingerprint"`, using the exact printed value.

An independent nested repository may need a Superteam-owned `.gitignore` pair. The plan calls this out as `MANAGED_IGNORE`. Existing ignore coverage is preserved, and an existing submodule is registered without conversion, update, staging, or gitlink commit. External repositories are stored using normalized `../` paths.

To unbind a member, first show the remove plan and make clear that no Git data will be deleted:

```bash
bash "$plugin_root/scripts/st-project.sh" repository remove "$project_path" --id "api"
```

Only after confirmation, repeat it with `--apply --plan-fingerprint "$plan_fingerprint"`, using the exact printed value. Remove deletes only the manifest binding and the exact Superteam-owned ignore pair, when present. It never deletes the repository directory, branch, worktree, remote, submodule, gitlink, or `.git` data. A missing or mismatched target can still be unbound, while every other registered member must revalidate as its declared real Git root.

`status` and `doctor` always report `root` first and then members in manifest order. They resolve every stored path again and explicitly report missing, mismatched or duplicate Git roots, dirty worktrees, detached HEADs, and missing upstreams. These commands remain read-only.

## Safe Repository Set pull

Run `pull` only after the user explicitly asks to update the Project. Capture the target Project path before resolving the separate bundle path, validate the bundle root, and invoke:

```bash
bash "$plugin_root/scripts/st-project.sh" pull "$project_path"
```

The command processes `root` first and then every registered repository in manifest order. Immediately before each update it resolves the declared path again and verifies that it is the expected Git root. A dirty worktree, detached HEAD, missing upstream, missing path, Git-root mismatch, or duplicate real Git root is `skipped`. An eligible repository receives only `git pull --ff-only`, with submodule recursion disabled; Superteam never stashes, checks out, merges, rebases, repairs, pushes, or updates a submodule. A failed repository does not stop later repositories.

Report the command's complete output to the user. Each repository includes `PULL_STATUS`, `BEFORE`, `AFTER`, and `REASON`. The summary counts `PULLED`, `UP_TO_DATE`, `SKIPPED`, and `FAILED`: `RESULT: COMPLETE` exits 0, `RESULT: PARTIAL` exits 2 after the full traversal, and `RESULT: FAILED` exits 1 when the Project cannot be parsed or the run cannot start.

## Safety contract

- Use Git, Bash, and POSIX base utilities only.
- Never create a remote, push, clone, stash, merge, or rebase implicitly.
- Root Repository is always included in project inspection and safe updates.
- Keep user paths, repository credentials, and remote URLs out of the manifest.
