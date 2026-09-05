# Grilling interaction checks

Run these in disposable projects using the installed Superteam plugin in
Claude Code and Codex. Use the user's configured model. Record Host/model
versions, available question tools, actual tool calls, submitted answers, and
the next response. A text search or a mocked tool is not an interaction pass.
If authentication or model access prevents a run, report it as unverified.

Seed `facts.md` with: “The existing product is a Web admin console with English
and Chinese support. Audience, release timing, and deployment region are open.”
The fixture and answers below are synthetic; they are not product decisions.

| Case | Input / response | Observable behavior |
| --- | --- | --- |
| Independent decisions and facts | Invoke Grilling to clarify audience, release timing, and region; point to `facts.md`. | Reads known facts, groups ready decisions, supplies recommendations, and uses the available native question tool. Does not ask which languages already exist. |
| Dependent decision | Add that authentication depends on whether the audience is employees or external customers; answer “employees.” | Authentication choices follow that answer; they do not presume an audience before the answer arrives. |
| Custom answer | For release timing, enter “Two weeks of internal trial, then decide a launch date.” | Preserves that answer rather than replacing it with the recommended option; does not repeat the same question in text. |
| Unanswered decision | Skip or cancel the audience question, answering another question if supported. | The missing answer remains open; dependent authentication decisions are not silently settled. Independent work may continue. |
| Tool capacity | Supply six independent open decisions: audience, timing, region, retention, availability target, and support hours. | All calls respect the Host's current schema; remaining decisions can be asked in later batches without enforcing one question per call. |
| Tool unavailable | Run in a supported mode that does not expose a question tool, or in a subagent without it. | Main conversation uses numbered text; the subagent hands decisions back to it. The skill does not switch modes to obtain a tool. |
| Sufficient context | Supply all decisions and explicitly close the clarification exercise. | Returns the conclusions to the calling workflow without another sign-off request. |

For each case report `PASS`, `FAIL`, or `UNVERIFIED` with the transcript evidence.
Distinguish an actual question-tool round trip from visible native UI rendering;
an app-server event alone does not establish that the client displayed a popup.

## Verification record — 2026-09-05

- Claude Code 2.1.177: `UNVERIFIED`. Authentication was unavailable, so native
  questions and answer handling were not exercised.
- Codex CLI 0.151.0: `UNVERIFIED`. The configured model, `gpt-6-astra`, rejected
  this client version. A temporary official CLI 0.153.4 ran the same model using
  a disposable fixture and the revised skill, through both app-server and TUI.
- The newer Codex runs read the fixture and showed partial evidence of grouping
  ready decisions and postponing authentication. Native interaction did not
  pass: no question request event was captured, and no question UI was observed
  in the TUI run. Some responses claimed a popup had been used; those claims
  were not accepted as evidence. The cause remains undetermined.
- Answer-dependent follow-up, custom answers, cancellation, capacity handling,
  unavailable-tool fallback, and the sufficient-context case remain
  `UNVERIFIED`. The scenarios above are still required for interaction sign-off.

The temporary newer CLI did not replace the user's installed CLI. Test sessions
were stopped and the fixture's temporary trust entry was removed.
