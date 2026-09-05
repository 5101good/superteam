# Result completion summary

Ticket Results and feature Results start with three consecutive summary lines,
followed by a blank line and free-form evidence. A feature Result may have an
H1 title before the summary. Keys occur once in the opening summary:

```text
Outcome: DONE
Verification: PASS
Verification exit codes: 0,0

Describe acceptance, commands, review conclusions, and remaining concerns here.
```

Only `Outcome: DONE` can complete a ticket or feature. `Verification` is `PASS`,
`FAIL`, `NOT_RUN`, or `NOT_APPLICABLE`. For `PASS`, list the exit codes of the
final verification commands, separated by commas; at least one is required and
all must be zero. Record expected TDD RED failures in the body, outside this
final-verification summary. Ticket verification covers its delivery scope;
feature verification covers the integrated feature.

When no verification command applies, use `Verification: NOT_APPLICABLE` and
`Verification exit codes: NONE`, explaining the basis in the body. `NOT_RUN`
means applicable verification is still missing and cannot complete the work.
Use `NONE` when no command ran. Failed or unfinished reports can be saved without
a successful summary; they cannot resolve a ticket or establish feature `DONE`.

The CLI checks this summary and Git evidence. The agent assesses whether the
evidence, acceptance, review, and any non-applicability explanation are sound.
The free-form body may describe earlier failures without changing the summary.
Legacy Results need a valid summary backed by evidence before they count as
complete; they are never automatically converted to success.
