# Contributing

## Development requirements

Run the test suite with Bats. Runtime code must work with Git, Bash 3.2 or newer, and POSIX base utilities on macOS, Linux, and WSL.

## Changes

Keep changes small and auditable. Public project URLs must point to
[github.com/5101good/superteam](https://github.com/5101good/superteam). Do not
add private identities, credentials, absolute user paths, or
environment-specific project details. Update tests whenever the public release
contract changes.

## Local verification

```bash
bats tests
find scripts -type f -name '*.sh' -print0 |
  while IFS= read -r -d '' script_file; do
    bash -n "$script_file"
  done
bash scripts/st-release-audit.sh .
```

The Bats suite uses real temporary Git repositories and local bare remotes. See
`RELEASING.md` for the release checklist.
