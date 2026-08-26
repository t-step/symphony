# Contract: New `WORKFLOW.md` Front-Matter Fields

`WORKFLOW.md` is Symphony's one runtime configuration surface (spec Assumptions). This documents the
additive fields this feature introduces, in the same "cheat sheet" style as `SPEC.md` §6.4, for operators
and for the `Config.Schema` implementation.

## New fields

- `tracker.kind: local` — selects the local work-tracking source (contracts/local-tracker-adapter.md).
  Existing `tracker.kind` values (`github`, `gitlab`, `jira`, `linear`, `asana`, `memory`) are unchanged.
- `tracker.provider.path`: string, default `.symphony/local_tracker.json` — only meaningful when
  `tracker.kind: local`. **Structural** in that case (see below) — unlike `tracker.provider.*` for every
  other tracker kind, which stays dynamically reloadable.
- `agent_execution.kind`: string, default `"codex"` (absent = `"codex"`), `"codex" | "claude_code"` —
  selects the coding-agent execution integration (contracts/coding-agent-behaviour.md).
- `claude_code.*` — sibling embed to the existing `codex.*` embed, same shape class (command/launch
  settings, timeouts, an unattended-approval-mode setting). Exact field list is finalized during
  implementation once research.md R5/R7's one remaining confidence-flagged CLI detail (exact stream-json
  event-type names) is re-verified against the targeted Claude Code CLI version, mirroring how `SPEC.md`
  §10 already treats "the targeted Codex app-server version" (not this spec) as the protocol source of
  truth. At minimum, mirrors `codex.command` with a `claude_code.command` default (the `claude` CLI
  invocation, launched with `--bare --permission-mode bypassPermissions --strict-mcp-config` per
  research.md R5/R8 — confirmed flags, not placeholders) and a `claude_code.turn_timeout_ms`/
  `read_timeout_ms` pair analogous to `codex.turn_timeout_ms`/`codex.read_timeout_ms`.

  **`command` parsing model — an intentional divergence from `codex.command`, decided during the
  T022/T023 adversarial-review repair (2026-08-25).** `claude_code.command` and `codex.command` are the
  "same shape class" only in schema (both a single string field with the same validation), **not** in how
  that string is interpreted at launch time:
  - `codex.command` is interpolated into a `bash -lc "... && exec <command>"` script — a genuine shell
    command line, supporting shell quoting, `env VAR=x <command>` wrapper prefixes, and other shell
    operators, exactly as `bash -lc` would for any script.
  - `claude_code.command` is tokenized as a **plain whitespace-separated argv list**
    (`String.split/1`, no quote/operator awareness whatsoever) and spawned directly via
    `:spawn_executable` — never through a shell. A value needing an embedded space inside a single
    argument (e.g. a quoted flag value) is **not** supported and will not tokenize as a shell would: the
    quote characters end up as literal characters split across two argv entries instead of one argument.
  This is a deliberate, retained decision (not a defect to fix): direct-exec spawning removes any
  shell-injection surface from this launch path entirely, which the review judged worth keeping over
  mirroring `codex.command`'s shell semantics for symmetry's sake. See
  `SymphonyElixir.ClaudeCode.AppServer.resolve_command/0`'s doc comment and
  `claude_code_app_server_test.exs`'s "claude_code.command parsing contract" tests, which pin down both
  the supported case (appending additional whitespace-separated flags) and the explicitly-unsupported
  case (shell-style quoting) as regression tests.

## Structural vs. dynamic reload (IV-005)

`tracker.kind` and `agent_execution.kind` are **structural** — read once at process start, changes take
effect only on the next restart.

**Corrected exception**: `tracker.provider.path` is *also* structural, but **only when
`tracker.kind: local`** — this is a narrow, single-field carve-out, not a broadening of the two-selector
rule above. Confirmed by direct trace (research.md R9a) that `Tracker.adapter/0` and
`fetch_issues_by_states/1`/`fetch_issues_by_ids/1` read `Config.settings!().tracker` fresh on every call
with no snapshot at the orchestrator-read level, so a live change to `tracker.provider.path` for the
local tracker would switch the orchestrator to reading a *different data source's identity* — not new
credentials against the same dataset — mid-flight, between one dispatch tick and the next, silently
making every previously-visible local-tracker issue look "no longer visible" (deletion-equivalent per
§11.1) and misfiring reconciliation against attempts that are still genuinely running. This risk is
specific to a local file path identifying a distinct dataset; it does not apply to any hosted tracker's
`provider.*` fields (API key, endpoint, project slug), which only ever change *how* to reach the same
remote dataset, so those keep the dynamic-reload behavior below unchanged.

Every other field introduced here (`claude_code.*` runtime settings, and `tracker.provider.*` for every
tracker kind other than `local`) follows the **same dynamic-reload class as its sibling today**:
`tracker.provider.*` reloads exactly as every other tracker's `tracker.provider.*` already does for a
hosted tracker (a tracker-provider setting, not a tracker*-selection*), and `claude_code.*` reloads
exactly as `codex.*` already does (a coding-agent *runtime* setting, not an execution-integration
*selection*). So the restart-only set is: the two `kind` selector fields, plus `tracker.provider.path`
specifically when `tracker.kind: local` — this remains the smallest carve-out that avoids the identified
hazard without regressing hosted-tracker operators' ability to rotate credentials/endpoints without a
restart.

## Validation

Both new `kind` values plug into the existing per-tick and startup dispatch preflight validation
(`SPEC.md` §6.3): `tracker.kind: local` is validated by `Local.Adapter.validate_config/1`
(contracts/local-tracker-adapter.md) — including the new requirement that the local store must already be
explicitly initialized via `symphony local-tracker init` (research.md R2a); `agent_execution.kind:
claude_code` is validated the same way `codex.command` is validated today — presence/non-blankness of
`claude_code.command` (or its resolved default) before the scheduling loop starts, and re-validated per
dispatch tick per §6.3.

**New cross-field validation (research.md R6a)**: `agent_execution.kind: claude_code` combined with a
non-empty `worker.ssh_hosts` is invalid configuration and fails startup validation the same way — Claude
Code execution supports local execution only in this feature; `worker.ssh_hosts` remains fully supported,
unchanged, for `agent_execution.kind: codex` (the default). This does not degrade or remove any existing
`worker.ssh_hosts` behavior for Codex deployments; it only rejects a combination that was never
previously meaningful (Claude Code execution did not exist before this feature).

## `symphony local-tracker init` (new CLI surface, research.md R2a)

A new leading subcommand on the packaged CLI entrypoint (`CLI.evaluate/2`, `elixir/lib/symphony_elixir/cli.ex`)
— `symphony local-tracker init [path-to-WORKFLOW.md]` (optional `--reset` flag; exact flag/output
ergonomics are an implementation detail) — not a `mix` task, because the production deployment target
(the Burrito-packaged single binary) has no `mix`/Elixir toolchain available. It resolves
`tracker.provider.path` from the given `WORKFLOW.md` (default `./WORKFLOW.md`, same default as the
existing run behavior) and performs the one-time atomic creation of the data file and establishment
marker described in research.md R2a. This is purely additive to `CLI.evaluate/2`'s existing argument
grammar — every current invocation shape (no leading `local-tracker` argument) is unaffected. It does not
start the orchestrator/scheduler.

## Backward compatibility (FR-006, SC-003)

A `WORKFLOW.md` that specifies neither new field parses and behaves exactly as it does today: `tracker.kind`
must still be one of the pre-existing supported values (no default — `SPEC.md` §6.4 already requires
`tracker.kind` to be present), and `agent_execution.kind` defaults to `"codex"`, so an existing Codex +
hosted-tracker deployment observes zero behavioral change.
