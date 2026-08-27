# Security Policy

## Scope

Superteam is a local plugin. It must not create remotes, push, or transmit project data as part of normal workflow execution.

## 1.0 Transaction Boundary

Version 1.0 protects normal local use: validated init/adopt inputs, path
validation, ordinary operation failures, handled Ctrl-C/HUP/INT/TERM
interrupts, and caller-provided Git environment isolation. Failed operations
use the documented rollback path and do not stage, commit, change remotes, or
publish a partial Project configuration in those supported cases.

Superteam assumes that another local process is not actively replacing Project
files or directories while an operation is running. Its Git and Bash runtime
is not intended to isolate mutually untrusted processes on the same machine.

## Reporting

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/5101good/superteam/security/advisories/new).
Do not include sensitive details in a public issue.

## Handling

Security fixes should include a minimal reproduction, a regression test when
practical, and release notes that describe user impact without exposing
unnecessary exploit detail.
