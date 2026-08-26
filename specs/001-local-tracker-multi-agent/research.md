# Phase 0 Research: Local Work Tracking and Selectable Coding-Agent Execution

Feature: [spec.md](./spec.md) | Plan: [plan.md](./plan.md)

The frozen spec left every concrete mechanism to this planning stage (FR-003/FR-011: "left unspecified
here and belongs to the planning stage"; FR-013: "by whatever concrete initialization mechanism the
planning stage selects"). This document resolves each of those with a decision, rationale, and the
alternatives considered, grounded in the current implementation (`elixir/lib/symphony_elixir/`) and
upstream `SPEC.md`.

## R1. Local work-tracking source: storage mechanism

**Decision**: A single durable JSON file per deployment (default
`.symphony/local_tracker.json`, path resolved the same way `workspace.root` already resolves relative
to `WORKFLOW.md`), read/written with `Jason` (already a dependency), with all writes going through a
write-temp-file + atomic-rename sequence. All access — reads and the one lifecycle write — is mediated
by a single named `SymphonyElixir.Local.Store` GenServer (see R1a below) rather than each caller doing
its own unsynchronized `File.read`/`File.write`.

**Rationale**: FR-004 only requires surviving a process restart on the same host — not a query language,
not multi-GB scale. It does NOT exempt the design from Symphony's actual concurrency model: confirmed by
direct trace of `orchestrator.ex` (`Task.Supervisor.start_child/2`, called once per dispatched issue) and
`Config.max_concurrent_agents_for_state/1` that one deployment routinely runs multiple work-item attempts
as genuinely concurrent OTP processes, and tool execution (`Tracker.execute_bound_agent_tool/4`) happens
synchronously inline within each attempt's own process — so two attempts for two different issues can
call into the local tracker's lifecycle-write tool at overlapping wall-clock instants. This is Symphony's
first local-file writer shared across concurrent callers (every existing tracker adapter's "write" is a
remote API call that serializes at the provider; `WorkflowStore` only ever reads `WORKFLOW.md`), so R1a
below is required regardless of file format. Given that a single-writer-owner discipline is required
either way, Constitution Principle V (Avoid Unnecessary Abstraction) and II (Minimize Fork Delta) still
weigh against introducing a SQL engine: `ecto` is already a dependency but is used purely for
`embedded_schema` config validation (`Config.Schema`), not as a database connection — adding real SQL
storage would require `ecto_sql` + a DB adapter (e.g. `ecto_sqlite3`) + a `Repo` + migrations, none of
which exist in this codebase today, AND would still need the same kind of single-writer discipline
`ecto_sqlite3` gives you for free at the cost of two new dependencies and migration machinery — a strictly
worse trade once the actual complexity driver (serialization, not file format) is understood. A plain
JSON file needs zero new dependencies, is human-readable/git-diffable (fitting the "repository-owned,
version-controlled" philosophy `SPEC.md` §5.1 already applies to `WORKFLOW.md`), and is trivially
inspectable by "a person or another tool" per the spec's edge case about out-of-band edits.

**Alternatives considered**:
- *SQLite via a new `ecto_sqlite3` dependency* — reconsidered after identifying the concurrency hazard
  (R1a) and still rejected: it does not remove the need for single-writer serialization (SQLite itself
  needs it under concurrent writers), so it only trades "add one GenServer" for "add two new dependencies
  + a `Repo` + migrations" to solve the same problem, contradicting Principle V.
- *`:dets` (OTP built-in term storage)* — rejected: binary format is not human-readable/diffable, and
  `:dets` has known table-size and corruption-recovery quirks that add operational surface for no
  benefit at this scale.
- *One file per issue in a directory* — considered for git-diff friendliness (one issue changed = one
  file changed) but rejected as first-cut scope: it requires directory-level atomicity reasoning
  (rename a whole tree is not atomic) and a listing/index step that a single JSON file gets for free.
  Left as a documented future refinement if operators report merge-conflict pain, not required by any
  FR/SC here.

## R1a. Local work-tracking source: concurrent-writer safety

**Decision**: `SymphonyElixir.Local.Store` is a named singleton `GenServer` (started conditionally, only
when `tracker.kind: local` is the active structural selection — mirroring how the OPTIONAL HTTP
observability extension in `SPEC.md` §13.7 is only started when configured), mirroring `WorkflowStore`'s
`start_link(name: __MODULE__)` pattern. `Local.Adapter.fetch_issues_by_states/1`,
`fetch_issues_by_ids/1`, and the `local_tracker_set_state` agent tool all go through
`GenServer.call(Local.Store, ...)` rather than touching the file directly; the GenServer's mailbox
serializes every read and write against the file, so two concurrently-running work-item attempts can
never race a read-modify-write cycle against each other.

**Rationale**: Confirmed via direct trace (orchestrator.ex `Task.Supervisor.start_child/2` per dispatched
issue; no existing shared-mutable-file-across-concurrent-writers precedent anywhere in the codebase) that
this is a real hazard, not a hypothetical: without serialization, two attempts finishing their own
`local_tracker_set_state` call at overlapping instants could each read the same on-disk snapshot, mutate
different keys in memory, and the second writer's atomic rename would silently discard the first writer's
change (a classic lost-update). `GenServer` is the idiomatic, already-dominant concurrency primitive in
this codebase (`WorkflowStore`, the orchestrator itself) and needs no new dependency — `mix.lock` has no
mutex/lock library, so a bespoke file-lock would be more code than reusing the pattern already used
everywhere else here.

**Alternatives considered**:
- *No serialization, rely on POSIX atomic rename alone* — rejected: atomic rename only guarantees a
  reader never observes a torn file; it does nothing to prevent two independent read-modify-write cycles
  from silently overwriting each other's in-memory changes (the lost-update case above only requires
  R1's atomicity, not this GenServer, to still corrupt no bytes while still losing a whole mutation).
- *OS-level file locking (`flock`)* — rejected: adds an external-process-coordination concern (locking
  across OS processes) that this codebase has no existing pattern for, to solve a problem that is
  entirely within one BEAM VM; a GenServer already provides exclusive access within the VM at zero
  additional cost.
- *Per-issue `Agent`/ETS cache with periodic flush* — rejected: introduces a second, eventually-consistent
  copy of the data (the reason for the eventual sync, and its failure mode on crash) for no benefit over
  `GenServer.call` directly performing the atomic write inline; adds complexity Principle V weighs
  against.

## R2. Local tracker: distinguishing "not yet established" from "corrupted"/"lost" (FR-013)

**Decision (twice-revised — this pass replaces the marker-with-self-heal design from the prior
correction with explicit initialization)**: File-absence-at-the-data-path is still not, by itself, a
reliable "not yet established" signal — that part of the prior correction was and remains right, for the
reason already established: a data file that once existed and is later deleted while Symphony is stopped
is, from a restart's point of view, indistinguishable from a path that was never used. What this pass
corrects is *how* Symphony learns the difference. The prior design kept a second, independently-durable
marker file (`<path>.established`) but let `Local.Store` write it **implicitly**, mid-read, whenever
ordinary polling encountered "data present, marker absent" (a "self-heal"). A second review correctly
identified this as a fragile inference: it silently promotes an *ambiguous* filesystem condition — which
could just as easily be a partial backup restore, or an interrupted/half-completed operation — into "this
is now an established store," using ordinary runtime code that was never meant to be an operator-facing
initialization API in the first place.

**Corrected model**: Symphony's ordinary runtime — startup validation, polling, dispatch, reconciliation,
the `Local.Store` GenServer's own read/write path — **never creates or completes either file**, under any
circumstance, for any reason. Establishment happens only through one small, explicit, separately-invoked
operation, `symphony local-tracker init` (R2a below). This mirrors how every *other* tracker adapter
already works: Symphony never auto-creates a GitHub repository, a Jira project, or a Linear team just
because `tracker.kind` names one and the configured target doesn't exist yet — the hosted resource must
already be provisioned before Symphony is pointed at it, and if it isn't, `validate_config/1` fails
startup the same way for every adapter (confirmed: `Local.Adapter.validate_config/1` slots into the exact
same `WorkflowStore.init/1` → `Config.validate_settings/1` → `Tracker.validate_config/1` chain every
hosted adapter's `validate_config/1` already uses — `workflow_store.ex:66-75,156-165`, `config.ex:122`,
`tracker.ex:76-81` — no new plumbing). The local tracker's "hosted resource" is just a file pair instead
of a remote account, but the same discipline now applies: it must be explicitly provisioned first.

The two files are unchanged in shape and location — the data file at `tracker.provider.path` (default
`.symphony/local_tracker.json`) and a sibling marker at `<tracker.provider.path>.established` (default
`.symphony/local_tracker.json.established`, containing `{"established_at": "<RFC 3339 timestamp>"}`) —
both still written through R1's atomic write-temp+rename path. What changed is that **only R2a's explicit
init operation may write either file**; nothing else ever does.

**Read/open decision table** (evaluated on every store-open — startup validation and each dispatch-tick
per `SPEC.md` §6.3 — by ordinary runtime code, which only ever reads):

| Marker | Data file | Outcome |
|---|---|---|
| absent | absent | **Not yet initialized.** `{:error, :local_tracker_not_initialized}` — operator-visible startup/dispatch-preflight failure, same failure *class* every other adapter's missing-config error already uses. Remediation: run `symphony local-tracker init`. Ordinary runtime never writes anything in response to this. |
| absent | present (valid or not) | **Ambiguous — never auto-resolved.** `{:error, {:local_tracker_ambiguous_state, :marker_missing}}`. This is the state a partial backup restore (data file only), an interrupted `init` run, or an operator manually dropping a JSON file into place all produce. Ordinary runtime treats it exactly like "not yet initialized" for scheduling purposes (fails the same way) but with a distinguishing reason so the operator isn't misled into thinking this is a fresh/empty deployment — the data is not touched, inspected further, or promoted to "established" by anything except a deliberate re-run of `init` (R2a). |
| present | present, valid | Normal operation. |
| present | absent | **FR-013 established-state loss.** `{:error, {:local_tracker_corrupt, :missing_after_established}}` — operator-visible, source-level failure; `Local.Store` MUST NOT recreate an empty store. |
| present | present, invalid/corrupt | **FR-013 established-state loss.** `{:error, {:local_tracker_corrupt, reason}}` (unchanged from the original R2's corruption handling). |
| present, unreadable/corrupt | (any) | Same class as the row above — an unreadable marker is treated as established-state ambiguity/loss, never silently ignored or rewritten. |

**Operational scenarios**:

- *Fresh deployment*: neither file exists. Symphony refuses to start the scheduling loop
  (`{:error, :local_tracker_not_initialized}`, startup failure) until the operator runs
  `symphony local-tracker init`.
- *First initialization*: the operator runs `symphony local-tracker init` (R2a) before first starting
  Symphony — a deliberate, one-time, out-of-band action, not something Symphony's own poll loop ever does.
- *Normal restart*: both files present and valid → no writes, normal operation.
- *Store deleted while Symphony stopped*: marker survives (a separate file, untouched by whatever deleted
  the data file) → `present`/`absent` row → FR-013 loss, operator-visible, never silently reset.
- *Store deleted while Symphony running*: the same condition is discovered at the next
  `fetch_issues_by_states/ids` call (`orchestrator.ex:263`'s `maybe_dispatch/1` tick, confirmed as the
  actual per-tick detection point — `WorkflowStore`'s `validate_config/1` only re-runs at boot or when
  `WORKFLOW.md`'s own content changes, not every tick, so the running-time case is caught by the existing
  read path, not a new periodic re-validation) → FR-008.4/FR-013's existing skip-tick-and-retry behavior,
  leaving running attempts undisturbed, with the marker present confirming this is loss, not fresh-init.
- *Store corruption*: unchanged FR-013 handling, either file.
- *Partial restore from backup (data file only, no marker)*: the `absent`/`present` ambiguous row — never
  silently accepted as established, never silently discarded either; requires the operator to explicitly
  re-run `init`, which (R2a) safely completes establishment over already-valid data without touching it,
  or to restore the marker file from the same backup if they have it.
- *Copying/restoring the data file without auxiliary metadata*: identical to the case above — this is
  exactly what the ambiguous row exists to catch, by design, rather than guessing.
- *Deliberate reset*: `symphony local-tracker init --reset` (R2a) — fully explicit, never inferred from
  file absence/loss.
- *Repository checkout / `.gitignore`*: `.symphony/local_tracker.json` and
  `.symphony/local_tracker.json.established` (the literal default paths, not a blanket `.symphony/`
  ignore) are added to `elixir/.gitignore`, matching the narrow, path-specific ignore pattern this repo
  already uses for `.codex/original-user-prompt.txt` (confirmed: `.codex/` itself is not blanket-ignored —
  only that one file path is; the prior pass's "mirrors `.codex/`'s existing treatment" claim overstated
  what that precedent actually establishes, and is corrected here). An operator who overrides
  `tracker.provider.path` to a custom location is responsible for gitignoring that path themselves, same
  as they would be for any other repo-local runtime file. A fresh `git clone`/`git clean -fdx` therefore
  always reproduces the "not yet initialized" row — expected and requires the same explicit `init` step as
  any other fresh deployment, not a special case.
- *Human/operator comprehensibility six months later*: one mental model — "if Symphony won't start because
  of the local tracker, run `symphony local-tracker init`; if it refuses because it looks ambiguous or
  lost, go look at what's actually on disk before doing anything, because something unexpected happened" —
  replaces the prior design's decision table of when self-healing was safe versus not.
- *No persistent scheduler state*: unaffected — this remains entirely `Local.Store`/tracker-adapter-owned
  durability metadata, not scheduler state, unchanged from the original constraint.
- *No second runtime configuration surface*: `local-tracker init` is a one-time administrative operation
  invoked outside of, and before, Symphony's own process lifecycle — it reads `WORKFLOW.md` once to
  resolve `tracker.provider.path` and exits; it does not add a field, flag, or file Symphony's *running*
  configuration resolution pipeline (`SPEC.md` §6.1) has to know about.

**Alternatives considered**:
- *The prior pass's marker-with-self-heal design* — superseded by this pass for the reason given above:
  it is materially safer for ordinary runtime code to never write a file that changes the store's
  established/not-established status, and to instead require exactly one, clearly-named, explicit action
  for that transition, than to have polling code infer intent from an ambiguous filesystem condition.
- *No marker at all — infer everything from data-file presence alone* — rejected, unchanged from the
  original review: this is the exact blind spot FR-013 exists to close (cannot tell "never established"
  from "established, now missing").
- *Explicit init with no marker file (rely on data-file presence alone once "initialized")* — rejected:
  this has exactly the same restart-loss blind spot as no marker at all the moment the data file is
  deleted after init runs; the marker's independent durability is still required, only *how it gets
  written* changed in this pass.
- *A containing-directory-level signal (e.g. directory ctime, a `.gitkeep`)* — rejected: directory
  creation-time metadata is platform-inconsistent and not something this codebase's Elixir/OTP file APIs
  treat as a first-class, portable signal (unlike a file's own content, which `File.read`/`Jason.decode`
  already handle uniformly across the supported macOS/Linux targets); it also does not distinguish "the
  directory pre-existed for unrelated reasons" from "Symphony established a tracker here."
- *A field inside the same data file* — rejected as explained above: it cannot survive the exact failure
  mode (deletion of that file) it needs to detect.
- *A store with intrinsic persistent identity/generation metadata embedded in the data file itself, no
  separate marker* — considered directly per this pass's review prompt, and still rejected for the same
  structural reason as the single-file alternatives above: any identity that lives *inside* the data file
  dies exactly when that file is deleted, which is precisely the failure FR-013 requires Symphony to
  detect. A second, independently-durable file remains necessary; what this pass changes is only that its
  *creation* is now bound to one explicit operation instead of inferred by ordinary runtime code.

## R2a. Explicit local-tracker initialization: contract and CLI surface

**Decision**: A new operation, `symphony local-tracker init [path-to-WORKFLOW.md]` — a leading subcommand
on the existing packaged CLI entrypoint, not a `mix` task. Confirmed this distinction is load-bearing, not
cosmetic: the packaged Burrito single-binary target (`macos_arm64`/`macos_x86_64`/`linux_arm64`/
`linux_x86_64`, `mix.exs:106-119`) and the `escript` target (`mix.exs:97-103`) both point at the same
`SymphonyElixir.CLI` entrypoint, and README.md's whole premise for Burrito packaging is that a production
operator has no `mix`/Elixir toolchain available — only the single binary. A `mix symphony.local_tracker.init`
task (mirroring the existing small-task precedent in `lib/mix/tasks/` — `pr_body.check.ex`,
`specs.check.ex`, `workspace.before_remove.ex`) would be invisible to that operator entirely. `init` must
therefore be reachable from `bin/symphony`/the packaged binary itself.

**Contract** (implementation retains full latitude over exact flag names/output formatting/error text —
this is the planning-level minimum, not a UI spec):

- `CLI.evaluate/2` (`cli.ex:39-58`) gains a new leading-subcommand branch recognized before the existing
  "run against a WORKFLOW.md path" behavior: a first positional argument of `local-tracker` with a second
  positional argument `init`, followed by an optional WORKFLOW.md path (default `./WORKFLOW.md`, exactly
  matching the existing run behavior's default resolution). Every existing invocation shape (no leading
  `local-tracker` argument) is completely unaffected — this is purely additive to the argument grammar.
- Effect: loads and parses the given `WORKFLOW.md` (reusing the same `Workflow.load/1` → `Schema.parse/1`
  path `WorkflowStore` already uses — no second parser), resolves `tracker.provider.path` (only meaningful
  when that workflow's `tracker.kind: local`; any other `tracker.kind` is a usage error, since there is
  nothing local to initialize), then performs an atomic two-file creation: write the data file
  (`{"format_version": 1, "issues": {}}`, via R1's atomic write-temp+rename) **first**, then the marker
  file (`{"established_at": "<RFC 3339 timestamp>"}`) **second** — the ordering matters for crash-safety:
  a crash between the two writes leaves "data present, marker absent," which is R2's ambiguous row, not a
  corrupt/torn file, and is exactly what re-running `init` is designed to safely resolve (see idempotency
  below). Prints a confirmation and exits `0`. Does **not** start the orchestrator, scheduler, or any
  supervision tree — `init` is a standalone, short-lived operation, not an alternate way to run Symphony.
- **Idempotency / safe re-run**: if both files already exist and are valid, `init` refuses by default
  (does not touch anything) with a message explaining the store is already established — this prevents an
  operator from accidentally clobbering a live store by re-running `init` out of habit. If **only** the
  data file exists (valid or not) and the marker is missing — R2's ambiguous row, whether from a crashed
  prior `init`, a partial restore, or a hand-placed file — re-running `init` is exactly the sanctioned way
  to resolve it: if the existing data file parses as a valid store, `init` writes the marker to complete
  establishment **without modifying the data file's contents**; if the data file is present but does not
  parse, `init` refuses (this is not a case `init` can safely resolve — the operator must restore valid
  data or explicitly reset, below) with a clear error rather than silently discarding it.
- **Deliberate reset**: a `--reset` flag (exact name is an implementation detail) is required to
  overwrite/replace an already-established store — it deletes both files (if present) and performs a
  fresh two-file creation as above. Without `--reset`, `init` never overwrites existing valid data.
- **Concurrency with a running Symphony process**: `init` is a separate, short-lived OS process invocation
  — it is not synchronized with a live `Local.Store` GenServer in a separately-running Symphony process
  (out of scope, matching R1's existing single-deployment-durability scope: this codebase does not
  synchronize cross-process writers to the local store, per R1a's own stated boundary). An operator who
  runs `init --reset` against a store an already-running Symphony deployment is actively using produces
  the same class of outcome any other out-of-band edit to the data file already produces (spec Edge Case:
  "What happens if a work item's lifecycle state is changed outside of Symphony... while a run for that
  item is active?") — this is an existing, already-accepted scope boundary, not a new gap introduced here.

**Rationale**: This is the smallest mechanism that gives FR-013's required distinction an unambiguous,
comprehensible operator model: "the store is provisioned by one explicit action, exactly like every other
tracker's underlying resource already has to be," rather than a set of implicit rules ordinary polling
code must get right on every read. It adds one CLI subcommand (a real but small, first-of-its-kind
addition to `CLI.evaluate/2`'s argument grammar) and reuses every other piece of existing machinery
(`Workflow.load/1`, `Schema.parse/1`, R1's atomic write path) — no new dependency, no new process type, no
persistent scheduler state, no second runtime configuration surface.

**Alternatives considered**:
- *A `mix` task only, no packaged-CLI subcommand* — rejected: confirmed unreachable by a production
  operator running the Burrito-packaged binary, which is the deployment target README.md documents as the
  normal one.
- *Tie initialization to "whatever operation first creates/installs local work" (e.g. auto-init on the
  first hand-edit or first seeding-tool write)* — rejected: this is out of scope per the frozen spec's own
  Non-Goals ("Deciding how work enters the local work-tracking source... is out of scope"), and it would
  reintroduce exactly the kind of implicit, ordinary-code-path establishment this pass is removing — there
  is no single, well-defined "first write" event to hook if work can enter the store by hand-editing JSON,
  a future seeding tool, or any other means.
- *No explicit init at all; refuse forever if the store is missing, no distinguishing detail between
  "never" and "lost"* — rejected: technically avoids ever silently auto-resetting (satisfies FR-013's
  prohibition), but fails FR-013's affirmative requirement to *distinguish* the two states in a way an
  operator can act on differently — a fresh deployment's remediation ("run init") and an established-loss
  incident's remediation ("investigate what happened to your data, then decide whether to restore or
  reset") are genuinely different operator actions, and collapsing them into one undifferentiated error
  would be a worse operator experience than what this design provides at negligible extra cost (one
  additional file, one additional CLI branch).

## R3. Local tracker: agent-invoked lifecycle-write mechanism (FR-003, FR-011)

**Decision**: Implement the local tracker as a normal `SymphonyElixir.Tracker` adapter that also
implements the existing OPTIONAL `agent_tool_specs/0` + `execute_agent_tool/3` callbacks (exactly the
pattern `GitHub.Adapter`/`GitHub.AgentTool` already establish), exposing one tool,
`local_tracker_set_state`, that rewrites the current session's bound issue's `state` field via the R1
atomic-write path.

**Rationale**: FR-011 explicitly requires reusing "Symphony's existing tracker-write boundary" rather
than adding orchestrator-owned write APIs — `Tracker.bind_agent_tools/0` and
`Tracker.execute_bound_agent_tool/4` already exist precisely for this, are already provider-agnostic
(dispatch by adapter, not by tool name), and are already wired into both the Codex dynamic-tool channel
(`Codex.DynamicTool`) and — per R6 below — the new Claude Code MCP channel. Zero new orchestrator
surface; the local tracker looks, to `AgentRunner`/`Codex.AppServer`/the new Claude Code integration,
exactly like any other tracker with provider-native tools.

**Alternatives considered**: A dedicated orchestrator-level "local tracker write" function was
rejected outright — it is precisely what FR-011 rules out.

## R4. `SymphonyElixir.CodingAgent` behaviour shape

**Decision**: Define a new behaviour with the three callbacks `Codex.AppServer` already exposes as its
public API — `start_session(workspace, opts) :: {:ok, session} | {:error, reason}`,
`run_turn(session, prompt, issue, opts) :: {:ok, turn_result} | {:error, reason}`, and
`stop_session(session) :: :ok` — and retrofit `Codex.AppServer` with `@behaviour SymphonyElixir.CodingAgent`
(no functional change; it already satisfies this shape). `AgentRunner` resolves which module to call via
`Config` (see R9) instead of hardcoding `alias SymphonyElixir.Codex.AppServer`.

**Verified against actual current code** (this plan's prior draft asserted this shape without checking
it against the real function signatures — now confirmed by direct read of `codex/app_server.ex` and
`agent_runner.ex`): `Codex.AppServer.start_session/2` really does return `{:ok, session}` where `session`
is the map `%{port:, metadata:, approval_policy:, ..., thread_id:, workspace:, ...}`
(`app_server.ex:14-25,38-69`). `run_turn/4` really does return `{:ok, %{result:, session_id:, thread_id:,
turn_id:}}` (`app_server.ex:71-143`) — note this returned map has **no `session` key at all**. `stop_session/1`
really does match `%{port: port}` (`app_server.ex:145-148`). The three-callback shape is accurate; see
R7 below for what the *return value* of `run_turn/4` needs to carry, which the prior draft left
underspecified (Issue 3 from review).

**Rationale**: `AgentRunner.run_codex_turns/5`/`do_run_codex_turns/8` is the single call site that drives
session lifecycle (`start_session` once, `run_turn` per turn in a loop bounded by `agent.max_turns` and
tracker-driven continuation, `stop_session` in an `after` block). That loop, the retry/backoff decision
after a failed turn, and the continuation decision (`continue_with_issue?/2`, which reads back from
`Tracker`) are all orchestration concerns that must stay unchanged per IV-002 — they belong above this
seam, not inside it. Naming and formalizing exactly the shape already implicitly relied upon is the
smallest possible change: no new session-lifecycle concepts, no generic multi-provider registry
(explicitly out of scope per the spec's Non-Goals), just an interface extracted from working code.

**Alternatives considered**: A richer behaviour exposing lower-level primitives (raw message send/
receive) was rejected — it would leak Codex's JSON-RPC transport shape into the contract, violating
Principle VI (protocol handling must stay localized to its own integration) and forcing Claude Code's
integration to fake a foreign transport model instead of using its own.

## R5. Claude Code CLI: non-interactive launch and streaming

**Decision**: Launch per turn as `claude -p "<prompt>" --output-format stream-json --verbose
--include-partial-messages`, spawned the same way `Codex.AppServer` already spawns `codex app-server` —
via `Port.open/2` with `cd:` set to the workspace path (Claude Code has no dedicated cwd flag; process
working directory is the control, matching how Codex is launched today via a `bash -lc "cd ... && exec
..."` wrapper) — reading complete newline-delimited JSON lines off stdout the same way
`AppServer.receive_loop/6` already does for Codex's JSON-RPC stream.

**Rationale/evidence**: Confirmed against current Claude Code CLI documentation (`code.claude.com/docs`:
`headless.md`, `cli-reference.md`, `agent-sdk/streaming-output.md`) that `-p`/`--print` is the
non-interactive entry point and `--output-format stream-json` (with `--verbose` required for streaming,
and `--include-partial-messages` for incremental deltas) produces line-delimited JSON events — the same
transport shape (one JSON object per line on stdout) `Codex.AppServer`'s line-buffered `Port` reader
already handles, so the existing receive-loop pattern generalizes without a new transport abstraction.
Exit codes are `0` (success), `1` (failure), `130`/`143` (signal termination) — mapped the same way
`Codex.AppServer` already maps `port_exit` today.

**Confirmed this pass** (via `claude --help` on the installed v2.1.245 and `code.claude.com/docs/en/headless`,
superseding the prior "not independently re-verified" note for these specific items): `--verbose` really
is required for `--output-format stream-json` to actually stream — the docs state the pattern as "Use
`--output-format stream-json` with `--verbose` and `--include-partial-messages` to receive tokens as
they're generated," not merely "override verbose mode" as the bare `--help` line for `--verbose` alone
might suggest. Also newly identified and worth folding into the launch contract: `--bare` ("Minimal
mode: skip hooks, LSP, plugin sync, attribution, auto-memory, background prefetches, keychain reads, and
CLAUDE.md auto-discovery... Anthropic auth is strictly `ANTHROPIC_API_KEY` or `apiKeyHelper`... OAuth and
keychain are never read") is documented as "the recommended mode for scripted and SDK calls" and is
planned to become `-p`'s default in a future release; it still honors `--mcp-config`, `--allowedTools`,
`--append-system-prompt`, `--settings`, and `--add-dir` per its own compatibility table. Since Symphony's
launches are unattended automation exactly matching `--bare`'s stated use case, and since a project's own
`.claude/settings.json`/`.mcp.json`/`CLAUDE.md` are otherwise loaded even in an untrusted directory under
plain `-p` (per the headless docs' own trust-dialog note), `claude_code.command`'s default invocation
SHOULD include `--bare` — this also forces the `ANTHROPIC_API_KEY`-only auth path R8 already requires,
rather than that being a separately-enforced isolation rule.

**Confidence note (narrowed)**: exact event-type names inside the stream-json payloads (the Claude Code
analogue of Codex's `turn/completed`/`turn/failed`) were not independently re-verified line-by-line
against a live CLI run in this planning pass (deliberately — no real prompt/turn was executed during this
research pass) and MUST be confirmed against the installed Claude Code CLI version's own `--help`/schema
output during implementation, the same way `SPEC.md` §10 already requires implementers to treat the
*targeted* Codex app-server version as the protocol source of truth rather than the spec text. This is
now the only remaining low-confidence item from the original R5.

## R6. Claude Code: tool exposure (tracker agent tools) — corrected process topology

**Prior plan's gap**: The original decision below is corrected. It asserted, without verifying, that
"`claude` spawns the configured MCP server as its own child process" and that this spawned process
"dispatches to `Tracker.execute_bound_agent_tool/4` exactly like `Codex.DynamicTool.execute/4` does
today." Those two claims do not compose: `Codex.DynamicTool.execute/4` is an ordinary Elixir function
call, invoked synchronously from *inside the same BEAM process* by `Codex.AppServer`'s own receive loop
when it sees an `item/tool/call` JSON-RPC message arrive on the *same* stdio `Port` Symphony already
holds open to the `codex app-server` subprocess (confirmed: `app_server.ex` — `run_turn/4`'s
`tool_executor` closure calls `DynamicTool.execute/4` directly, invoked from `await_turn_completion/4`'s
handling of messages read off that one Port). A stdio MCP server spawned as `claude`'s own child OS
process is a *different* process tree entirely — it is not a child of the Elixir BEAM, has no Port
Symphony holds, and cannot call an Elixir function that only exists inside the running Symphony VM
without some explicit IPC channel, which the prior plan never specified. This is exactly the "implicit
cross-process function call" gap identified in review.

**Decision (corrected)**: Symphony hosts the MCP server itself, inside the same BEAM process as the
orchestrator, as an HTTP endpoint via `Bandit` (already a dependency — the same library `SPEC.md` §13.7's
OPTIONAL observability HTTP extension already uses, which documents the exact pattern reused here:
bind loopback (`127.0.0.1`) by default, support an ephemeral port, and treat listener changes as
restart-required). A new `ClaudeCode.MCPServer` starts its own small Bandit listener — independent of
the separately-OPTIONAL observability dashboard, since MCP tool exposure must work whether or not an
operator has enabled `server.port` — bound to `127.0.0.1:0` for the lifetime of one run, and Symphony
generates a per-run `--mcp-config` JSON pointing `claude` at it as a **remote HTTP** server entry:
`{"mcpServers": {"symphony_tracker": {"type": "http", "url": "http://127.0.0.1:<port>/mcp/<run-token>"}}}`.
`claude` connects **out** to this URL over an ordinary loopback HTTP request; Symphony never spawns a
second OS process for tool exposure at all. On each tool call, the HTTP handler (running as ordinary
Elixir/Plug code inside the same BEAM process the orchestrator runs in) calls
`Tracker.execute_bound_agent_tool/4` directly — a genuine in-process function call, exactly the same
class of "already inside the BEAM" call `Codex.DynamicTool.execute/4` makes today, just reached over a
loopback HTTP request instead of a stdio Port message. The per-run token in the URL path scopes each
connection to its own run's tracker binding (defense in depth on top of loopback-only binding, closing
FR-009 isolation for this channel).

**Rationale/evidence**: Confirmed via `claude mcp add --help`, `claude mcp add --transport http|sse`
examples, and Claude Code's current MCP reference documentation
(`code.claude.com/docs/en/mcp`) that `--mcp-config`/`.mcp.json` entries support a `"type": "http"`
(also accepting the MCP-spec alias `"streamable-http"`) entry with a `"url"` field, alongside the local
stdio `"command"`/`"args"`/`"env"` entry shape — i.e. remote HTTP MCP servers that the CLI connects *out*
to are a first-class, documented transport, not something inferred or assumed. This makes Symphony the
MCP **server** and `claude` the MCP **client**, which is the standard client/server direction for HTTP
transport and requires no new dependency (Bandit is present), no distributed-Erlang setup (none exists
in this codebase today and none is added), and no second OS process whose stdio Symphony would otherwise
need some other channel to reach. This keeps FR-007's localization requirement intact: the MCP wire
protocol (HTTP handler, JSON-RPC-over-HTTP framing) lives entirely inside `ClaudeCode.MCPServer`, and
`Tracker` itself stays protocol-agnostic exactly as before (`execute_bound_agent_tool/4` takes tool name
+ arguments + opts, with no assumption about which wire protocol produced them) — the only change from
the original plan is *how* a tool call physically reaches that function, not what receives it.

**Alternatives considered**:
- *Stdio MCP child process, as originally planned* — rejected once the process-boundary gap was
  identified: it requires either (a) Symphony reading that child's own stdout, which Port only lets
  the process that spawned a subprocess do, and Symphony does not spawn this one — `claude` does — or (b)
  some new IPC (distributed Erlang, a Unix domain socket, a second localhost TCP listener the child
  connects to) layered on top, which is strictly more moving parts than a Bandit HTTP endpoint Symphony
  already knows how to run.
- *Symphony's own Port for `claude` doubling as the tool-call channel (i.e. Claude Code speaks its tool
  calls over the same stdio stream as its turn output, the way Codex does)* — rejected: this is not how
  Claude Code's headless mode works. Claude Code's tool-exposure mechanism is MCP, a protocol
  independent of `--output-format stream-json`'s turn-event stream; there is no documented way to
  multiplex MCP tool calls onto the `stream-json` stdout stream instead of a real MCP transport.
- *Skipping tool exposure entirely for Claude Code* (agent can only edit files, never call
  `local_tracker_set_state` or a hosted tracker's provider-native tool) — rejected, unchanged from the
  original decision: it would silently break FR-003's workflow-directed lifecycle mutation, which nothing
  in the spec permits as a Claude-Code-specific carve-out.
- *SSE transport instead of HTTP* — rejected: `claude mcp add --help`'s own guidance is that SSE is
  deprecated in favor of `http` where available, and Symphony's server is one Symphony controls
  end-to-end, so there is no reason to target the deprecated transport.

## R6a. Claude Code MCP: process topology, session/issue binding, authentication, and remote-worker scope

This section fully specifies the process topology, request-binding, and authentication model R6 left
implicit, and resolves whether it works under `worker_host` (SSH remote execution). Investigated directly
against `agent_runner.ex`, `codex/app_server.ex`, `ssh.ex`, `workspace.ex`, and `tracker.ex` rather than
assumed.

**Process topology — one `ClaudeCode.MCPServer` per coding-agent run, not per Symphony process, per
worker host, or per turn.** `AgentRunner.run/3` (`agent_runner.ex:21-36`) already scopes one call to
exactly one issue's one run attempt, running inside its own `Task.Supervisor`-spawned process
(`orchestrator.ex`); `ClaudeCode.AppServer.start_session/2` starts exactly one `ClaudeCode.MCPServer`
Bandit listener as part of that same run's process tree — a direct child of the run's own supervision
subtree, not a globally-registered singleton and not one-per-turn. It is:

- **Started**: in `start_session/2`, once, before the first turn — mirroring exactly where Codex's
  `dynamic_tool_binding = DynamicTool.bind()` is captured once (`app_server.ex:41`) and where Codex's
  `Port` is opened once for the whole run.
- **Owned/lifecycle**: the run's own process (the same process `AgentRunner.run_codex_turns/5`'s `try`/
  `after` already wraps around `start_session`/`stop_session`, `agent_runner.ex:92-98`) — no separate
  supervisor, no registry, no `DynamicSupervisor` needed beyond what a Bandit `child_spec` started under
  the run's own linked process tree already provides.
- **Reused across turns**: Claude Code spawns a fresh OS process per turn (R7), but the MCP listener is
  *not* per-turn — the tracker binding and current issue don't change turn-to-turn within one run, so one
  listener instance serves every turn's tool calls for that run, started once and torn down once.
- **Stopped**: in `stop_session/1`, always, from the caller's `after` block (unchanged — R4/contract). If
  the run's process itself dies abnormally (BEAM crash, `Task.Supervisor` child killed), the listener dies
  with it automatically via ordinary OTP supervision — it is a linked child of that process, not a
  separately-supervised long-lived resource, so no extra cleanup code is needed for the abnormal-exit case
  beyond what already exists for every other per-run resource.
- **What happens on abnormal agent termination mid-turn**: the in-flight `claude -p` OS process for that
  turn exiting abnormally is handled entirely by `run_turn/4`'s existing failure path (R4/contract, `{:error,
  reason}`, routed into FR-008.2's attempt-failure/retry path) — this has no special interaction with the
  MCP listener, which simply keeps running (ready for the *next* turn, if the run continues) until
  `stop_session/1` tears it down in the outer `after` block regardless of how the last turn ended.

**Session/issue binding — no global lookup table, no "current issue" state.** `Tracker.bind_agent_tools/0`
(`tracker.ex:48-59`) returns a plain immutable map (`%{adapter:, tracker_settings:, tool_specs:,
secret_environment_names:}`) with no process reference or global identity — confirmed this is exactly the
same shape Codex already captures once per session. `ClaudeCode.AppServer.start_session/2` captures this
binding, plus the current `Tracker.Issue.t()`, **once**, and passes both directly into the
`ClaudeCode.MCPServer` process it starts for this run — the listener's own state (a Plug/Bandit process
holding `{dynamic_tool_binding, issue}` in its own initial state, not fetched per-request from anywhere
shared) *is* the binding. An incoming MCP tool-call HTTP request therefore cannot be misrouted to another
run's issue: there is no routing step at all, no map keyed by session/issue ID to look up — the process
handling the request only ever has one run's binding and one run's issue in scope, structurally, because
it was started with exactly that context and no other. This directly satisfies "do not rely on global
current-issue state": there is no global state of any kind in this design, only per-run process-local
state, exactly mirroring how Codex's `dynamic_tool_binding` already lives inside that one session's own
data, never in a shared table.

**Where the bound context lives, end to end**: `Tracker.bind_agent_tools/0` is called once, inside
`ClaudeCode.AppServer.start_session/2` (same call site pattern as `Codex.AppServer.start_session/2`,
`app_server.ex:41`) → the returned map plus the current issue are passed as the `ClaudeCode.MCPServer`
child's start arguments → held in that process's own state for the run's lifetime → read (never mutated)
on every tool-call HTTP request the listener handles → passed to
`Tracker.execute_bound_agent_tool/4` (`tracker.ex:61-74`) exactly as `Codex.DynamicTool.execute/4` already
does. No ETS table, no Registry, no additional process holds a copy — one process, one binding, for the
run's whole lifetime.

**Authentication/authorization — per-run listener plus a per-run unguessable token, both load-bearing.**
Two independent, minimal mechanisms, chosen because the process-per-run topology above is itself already
most of the isolation guarantee:

- The **per-run listener** means even with zero additional auth, a request reaching a given run's port can
  only ever invoke *that* run's tracker binding — there is no cross-run routing surface to exploit because
  each run's listener has no knowledge of any other run.
- A **per-run, cryptographically-random, unguessable token**, embedded in the URL path Symphony generates
  for that run's `--mcp-config` entry (`http://127.0.0.1:<port>/mcp/<run-token>`, R6), checked on every
  request before it reaches the tool-dispatch handler — this is the second, independent layer: even though
  each port already maps to exactly one run, the port number itself is a small, potentially-enumerable
  space on a shared host (visible via `netstat`/`ps` to any other local process), so the token is what
  actually prevents an unrelated local process (not just an unrelated *Symphony run*) from invoking this
  run's tracker tool merely by guessing or observing which ports are open. This is the smallest capability
  model that gives genuine session isolation without new auth infrastructure — no shared secret store, no
  TLS/certificate machinery (loopback-only, so unnecessary), no session-registry service.
- `--strict-mcp-config` (R8, confirmed CLI flag) ensures `claude` only ever attempts to reach the one MCP
  server entry Symphony explicitly generated for this run, ignoring any ambient `.mcp.json`/user-level MCP
  config that might otherwise expose unrelated tools.
- **Two concurrent Claude-backed work items cannot cross-call each other's tracker context** as a direct
  consequence of the above: each has its own ephemeral port (OS-assigned, guaranteed distinct) and its own
  random token; there is no shared listener, shared token store, or shared binding table between them to
  confuse.

**Remote worker (`worker_host`/SSH) compatibility — explicitly out of scope for this feature, not silently
dropped.** Confirmed by direct trace (`agent_runner.ex:24-47` → `codex/app_server.ex:192` vs. `:216` →
`ssh.ex:11-49`, plus `workspace.ex`'s separate remote-branch workspace creation) that Symphony's existing
remote-worker execution model:

- Has **no shared filesystem** between the orchestrator host and a worker host — the remote workspace path
  is independently resolved on the remote host via its own `pwd -P` shell round-trip
  (`workspace.ex:38-51,54-81`), and is not guaranteed (or expected) to equal the orchestrator-host path for
  the same issue.
- Has **no existing remote-file-delivery mechanism** — Codex's remote launch (`app_server.ex:230-238`)
  passes everything the remote `codex app-server` process needs via the SSH-wrapped shell command line and
  the JSON-RPC/stdio channel itself; nothing is `scp`'d, `rsync`'d, or otherwise written to the remote
  filesystem by Symphony today, confirmed by an empty search across `lib/` and `docs/`.
- Has **no existing SSH port-forwarding usage or documentation** — `SSH.ssh_args/2` (`ssh.ex:41-49`) is
  hardcoded to `[-T] [-p port] destination command`, no `-L`/`-R`/`-D` anywhere; whether a hypothetical
  `-R <remote_port>:127.0.0.1:<local_port>` reverse-tunnel would even work depends entirely on the
  *remote* host's own `sshd_config` (`AllowTcpForwarding`/`GatewayPorts`), which Symphony has no way to
  inspect, control, or fail loudly against in advance — a request to a "loopback" port that silently never
  gets forwarded (forwarding disabled server-side) fails as an unhelpful connection-refused deep inside a
  live coding-agent turn, not as a clear startup validation error.

Given that: (a) `worker_host`/SSH remote execution is not mentioned anywhere in the frozen `spec.md` or
upstream `SPEC.md` as a requirement of this feature — confirmed by direct grep of both, zero matches for
"worker_host"/"remote execution"/"ssh" as a normative requirement; (b) the frozen spec's own Assumptions
section explicitly states Claude Code "does not require Claude Code to expose every Codex-specific
capability — only the guarantees this specification's inherited invariants depend on," and none of
IV-001–IV-006 depend on remote-worker support specifically; and (c) building genuine remote-worker MCP
support today would require inventing either a new remote-file-delivery mechanism or an SSH-forwarding
bridge whose reliability Symphony cannot verify or control — a materially larger, less certain piece of
new machinery than anything else in this feature, for a capability nothing requires —

**Decision**: Claude Code coding-agent execution (`agent_execution.kind: claude_code`) supports **local
execution only** in this feature. `worker_host`/`worker.ssh_hosts` remain fully, unchangedly supported for
Codex (`agent_execution.kind: codex`, the default) — nothing about Codex's existing remote-worker behavior
is touched. This combination is invalid configuration, enforced at two points:

- **Config validation** (new cross-field check, alongside the existing per-adapter `validate_config/1`
  calls in the same `Config.validate_settings/1` pipeline, `config.ex:122`): `agent_execution.kind:
  claude_code` together with a non-empty `worker.ssh_hosts` fails startup validation with a clear message
  ("Claude Code execution does not support remote worker hosts in this release; unset `worker.ssh_hosts`
  or use `agent_execution.kind: codex`") — same operator-visible startup-failure class as every other
  config validation error (§6.3).
- **Defense in depth**: `ClaudeCode.AppServer.start_session/2` itself returns
  `{:error, :remote_worker_not_supported}` (routed into FR-008.2's attempt-failure/retry path, not a
  crash) if ever invoked with a non-nil `worker_host` despite the startup check — the same
  belt-and-suspenders pattern `CodingAgent.start_session/2`'s contract already requires for any
  dependency failure that prevents attempting a turn.

Because Claude Code is local-only, the `--mcp-config` file-delivery question resolves trivially: Symphony
writes the per-run MCP config JSON to a local temp path and passes it to a **locally**-spawned `claude`
process (a plain `Port.open/2`, exactly mirroring Codex's local, non-SSH branch — `app_server.ex`'s
`worker_host == nil` path) — no remote file needs to exist anywhere, and the loopback URL genuinely is the
same host's loopback for both Symphony and `claude`.

**Alternatives considered**:
- *SSH reverse port-forwarding (`-R`) bridging a remote `claude` to the orchestrator-hosted listener* —
  architecturally clean to add (no existing flag conflict) but rejected for this feature: its success
  depends on remote `sshd` configuration Symphony cannot verify, so a misconfigured remote host would fail
  silently/confusingly deep inside a turn rather than at startup validation — the opposite of this
  project's operator-visible-failure discipline, for a capability nothing in the spec requires.
- *A minimal MCP endpoint running on the worker host itself* (spawned alongside `claude` via the same SSH
  session) — rejected: this is a second, remote-host-resident BEAM-independent process that would still
  need some way to reach back into the orchestrator's live `Tracker` binding (raw tracker credentials
  cannot be shipped to it per FR-009), reintroducing a real IPC-design problem, not avoiding one.
- *Silently running Claude Code locally even when `worker.ssh_hosts` is configured, ignoring the setting*
  — rejected outright: this is precisely the "silently degrade existing worker-host semantics" outcome
  this pass was directed to avoid; an explicit, loud startup validation failure is the correct behavior
  instead.
- *Building full remote support now, since it is a plausible eventual requirement* — rejected per
  Constitution Principle V (avoid unnecessary abstraction absent a demonstrated requirement) and the
  decision criteria's preference for the smallest total architecture; left as a documented, explicit future
  extension rather than spent effort against a capability nothing currently requires.

## R7. Claude Code: session/turn continuation model — corrected to close the CodingAgent contract gap

**Prior plan's gap** (Issue 3 from review): the prior decision below had Claude Code *learn* its
`session_id` reactively from turn 1's own output, then required `run_turn/4` to "return an updated
opaque session term" so `AgentRunner` could thread it into turn 2. But `AgentRunner.do_run_codex_turns/8`
does not do this today, and never has: its recursive call at `agent_runner.ex:117-126` always passes the
**original** `app_session` from `start_session/2` forward into the next turn, unconditionally — the
`{:ok, turn_session}` value `AppServer.run_turn/4` returns is only ever used for its `session_id` in a
log line (`agent_runner.ex:111`) and is otherwise discarded. And `Codex.AppServer.run_turn/4`'s actual
return shape (`%{result:, session_id:, thread_id:, turn_id:}`, confirmed in R4) has no `session` key to
carry such a value even if `AgentRunner` did thread it. The contract's "MAY return an updated session...
MUST thread it forward" language was therefore asking for a mechanism that exists in neither Codex's
current return shape nor `AgentRunner`'s current loop — an implicit gap, not an implemented seam.

**Decision (corrected)**: Symphony — not Claude Code — chooses and owns the session identity, using
`--session-id <uuid>` (confirmed via `claude --help`: "Use a specific session ID for the conversation
(must be a valid UUID)"). `ClaudeCode.AppServer.start_session/2` generates one UUID (e.g. via
`Ecto.UUID.generate/0` — `ecto` is already a dependency), performs workspace/MCP-config preparation
(including starting the per-run `ClaudeCode.MCPServer` Bandit listener, R6), and returns an opaque
session map holding that fixed `session_id` plus the prepared MCP config path; it does **not** spawn a
long-lived process, since Claude Code's headless mode has none. Turn 1's `run_turn/4` spawns
`claude -p ... --session-id <the-generated-uuid>` (no `--resume`, since nothing exists yet to resume);
every subsequent turn spawns `claude -p ... --resume <the-same-uuid>`. The session identity **never
changes turn to turn** — this exactly mirrors Codex's own model, where `thread_id` is captured once in
`start_session/2` and reused unchanged for every continuation turn (confirmed upstream precedent:
`SPEC.md` §10.2, "Reuse the same `thread_id` for all continuation turns inside one worker run"; confirmed
in current code: `app_server.ex`'s `session.thread_id` is set once in `start_session/2` and never
reassigned by `run_turn/4`).

Because the session identity is now fixed at `start_session/2` for **both** integrations, the
`CodingAgent` contract's `run_turn/4` is corrected to match what `Codex.AppServer.run_turn/4` already
does today: it returns `{:ok, turn_result}` only, with no session value in the return at all. The
`ClaudeCode.AppServer` implementation returns the same `{:ok, turn_result}` shape — `turn_result` MAY
carry Claude-Code-specific fields but never a "next session" value, because there is no next session to
carry. This is the smallest correct fix: it adds no new return arity to the callback, requires no change
to `AgentRunner`'s existing recursive-call code (which was already, correctly, reusing the original
`app_session` unconditionally — the code was right; only the contract's prose was wrong), and removes the
"learn the session id reactively from stream-json output" step entirely, since Symphony already knows the
ID before turn 1 starts.

**Rationale/evidence**: Unlike the Codex app-server (one long-lived subprocess, one open connection
reused via JSON-RPC calls into that same live process for every turn), Claude Code's headless mode is one
full process invocation per turn; continuity across turns is transcript-based (stored under
`~/.claude/projects/...`) and resumed by session ID, per Claude Code's own session-management
documentation and confirmed via `claude --help`. This per-turn-process model is exactly the kind of
provider-specific lifecycle mechanic Principle VI requires to stay localized: `CodingAgent`'s 3-callback
contract deliberately does not assume "a process is now running" after `start_session`, so this asymmetry
is fully absorbed inside `ClaudeCode.AppServer` and invisible to `AgentRunner`'s turn loop, which only
ever sees `{:ok, session}` / `{:ok, turn_result}` / `:ok` — now with `session` genuinely never changing
after `start_session/2` for either integration, closing the gap instead of routing around it.

**Confidence note**: the exact interaction of `--session-id <uuid>` on a fresh turn 1, followed by
`--resume <uuid>` on turn 2+, is architecturally sound per the CLI's own documented flag semantics ("Use
a specific session ID for the conversation" / "Resume a conversation by session ID") and there is no
plausible alternative reading of those two flags, but it was not exercised against a live turn during
this planning pass (deliberately — this pass only ran discovery/help-oriented CLI commands, never a real
prompt) and MUST be confirmed against the installed Claude Code CLI version with one real run at
implementation time. This is an implementation-time verification item, not a foundational design
unknown. Separately confirmed and no longer a low-confidence item: `--continue` ("Continue the most
recent conversation in the current directory") targets "most recent," not an explicit ID, which remains
the reason it is unsuitable once multiple workspaces/issues run concurrently on one host — `--resume
<uuid>` is the only one of the two that names an exact session.

## R8. Claude Code: unattended auto-approval and credential isolation

**Decision**: Launch with `--permission-mode bypassPermissions` and authenticate via `ANTHROPIC_API_KEY`
scoped to the Claude Code subprocess's environment only, combined with `--bare` (R5) so Claude Code
cannot fall back to an interactive OAuth/keychain login even if `ANTHROPIC_API_KEY` were momentarily
unset — `--bare` makes that failure loud (missing auth surfaces as a launch/attempt failure through
FR-008.2) instead of silently prompting for a login Symphony can never answer. Following the exact
pattern `Codex.AppServer.tracker_secret_unset_command/1` and `tracker_secret_port_env/1` already use to
strip tracker secrets from the Codex child's environment, the Claude Code launch environment explicitly
excludes `OPENAI_API_KEY`/Codex's own auth file, and the Codex launch environment (unchanged) continues
to exclude `ANTHROPIC_API_KEY`.

**Rationale/evidence**: FR-009 is a hard requirement ("MUST NOT be required by, or leak into, another
coding-agent execution integration"). Since FR-010 already guarantees only one coding-agent execution
integration is ever active per deployment, isolation only has to prevent the *inactive* integration's
credentials from being readable by the *active* one's child process — the existing per-process `env:`
allow-list pattern in `Port.open/2` (already used for tracker secrets) generalizes directly: only pass
through the environment variables the active integration's profile documents needing.

**Confirmed this pass** (via `claude --help` on the installed v2.1.245): `--permission-mode` accepts the
enum `"acceptEdits" | "auto" | "bypassPermissions" | "manual" | "dontAsk" | "plan"` —
`bypassPermissions` ("Bypass all permission checks. Recommended only for sandboxes with no internet
access.") is confirmed to exist and is the correct choice here, not a guess: Symphony's per-issue
workspace isolation (IV-003/IV-006) is exactly the kind of sandboxed, non-interactive context this mode's
own documented caveat describes, and unlike `acceptEdits`/`dontAsk`/`auto`, it is the only mode
guaranteed not to fall through to an unanswerable interactive prompt for a non-file-edit action (e.g. a
shell command) mid-turn. Also confirmed: `code.claude.com/docs/en/headless` documents `ANTHROPIC_API_KEY`
as the correct unattended-auth environment variable, specifically in combination with `--bare` (R5) —
"In bare mode, Claude Code never reads OAuth credentials or the system keychain. For the Anthropic API,
set `ANTHROPIC_API_KEY` in the environment... with a key created in the Claude Console." This directly
answers the previously-open "is there a way to force API-key-only auth with no OAuth/browser fallback"
question: `--bare` is that mechanism, not a separate flag. This closes what was previously R8's only
confidence note — the permission-mode enum value and the auth-isolation mechanism are both now confirmed,
not assumed. Symphony's documented policy choice MUST still fail (not silently hang) any turn that
somehow still requires interactive confirmation, matching the "run MUST NOT stall indefinitely waiting
for user input" requirement Codex's integration already satisfies; `--strict-mcp-config` (confirmed via
`claude --help`: "Only use MCP servers from `--mcp-config`, ignoring all other MCP configurations") SHOULD
also be passed so a workspace's own `.mcp.json`, if present, cannot add unreviewed tools to an unattended
run — this was not in the original plan and is added here as a direct FR-009/credential-isolation
strengthening enabled by this pass's CLI research.

## R9. Coding-agent execution integration selection: config surface and reload semantics

**Decision**: New `agent_execution.kind` WORKFLOW.md field (`"codex"` default, or `"claude_code"`),
resolved once at process start alongside `tracker.kind` (see Constitution Check / IV-005), not
hot-reloaded. `AgentRunner` resolves the concrete `CodingAgent` module from this value at the point it
currently hardcodes `Codex.AppServer`.

**Rationale**: Directly required by FR-005/FR-006/FR-010 and by IV-005 as already revised in the frozen
spec (structural, restart-only selection). No new decision beyond what the spec already settled; captured
here only to record where in the config pipeline (`Config`/`Config.Schema`, same place `codex.*` is
resolved today) the field lives.

## R9a. `tracker.provider.path` reload semantics for `tracker.kind: local` (structural exception)

**Decision**: `tracker.provider.path` is a documented, narrow structural exception when
`tracker.kind: local` — read once at process start alongside `tracker.kind`/`agent_execution.kind`, not
hot-reloaded — while `tracker.provider.*` remains dynamically reloaded, unchanged, for every other
tracker kind (`github`/`gitlab`/`jira`/`linear`/`asana`).

**Rationale/evidence**: Confirmed by direct trace that this is a genuine live-behavior hazard, not a
theoretical one. `WorkflowStore.reload_state/1` (`workflow_store.ex:122-155`) replaces the entire
`Schema.t()` settings struct wholesale whenever `WORKFLOW.md`'s content hash changes — there is no
per-field diffing anywhere. `Config.settings!()` (`config.ex:34-43`) always returns whatever
`WorkflowStore` currently holds, and `Tracker.adapter/0`/`fetch_issues_by_states/1`/`fetch_issues_by_ids/1`
(`tracker.ex:33-41,87-91`) all call `Config.settings!().tracker` **fresh on every single invocation** —
there is no snapshot or pinning at the orchestrator-read level (only `Tracker.bind_agent_tools/0` snapshots
settings, and only for one coding-agent session's own tool calls, not orchestrator-wide reads). Concretely:
if `tracker.provider.path` changed between two dispatch ticks (within `WorkflowStore`'s 1-second poll
interval) for a live `tracker.kind: local` deployment, the very next tracker read would transparently
switch to reading a *different data source's identity* — not new credentials against the same remote
dataset (which is what a hosted tracker's `provider.*` reload already safely means today), but a
different local file with different issue IDs. Since the adapter contract already treats "an id present
in the old fetch but absent from the new fetch" as "no longer visible" (deletion-equivalent, per
`contracts/local-tracker-adapter.md` §`fetch_issues_by_ids`), a live path switch would make every issue
from the old file vanish from the orchestrator's perspective mid-flight, misfiring reconciliation's
stale-dispatch/lost-work handling (`orchestrator.ex:930`) against attempts that are still genuinely
running. This risk is unique to the local tracker's `path` field specifically — a hosted tracker's
`provider.*` fields (API key, endpoint, project slug) identify *how to reach the same dataset*, not a
different dataset's identity, so their existing dynamic-reload behavior stays correct and unchanged.

This is deliberately a single-field carve-out, not a blanket "all `tracker.provider.*` becomes
restart-only" rule — the review explicitly cautioned against over-broadening this, and there is no
identified problem with hosted-tracker `provider.*` fields staying dynamically reloadable today.

**Alternatives considered**:
- *Leave `tracker.provider.path` dynamically reloadable (original plan)* — rejected: demonstrated hazard
  above.
- *Make all `tracker.provider.*` fields restart-only, for every tracker kind* — rejected: broader than
  the identified problem, would regress hosted-tracker operators' ability to rotate credentials/endpoints
  without a restart, with no requirement in the spec motivating that regression.
- *Detect a live path change and treat it as a special "migrate to new source" event (re-poll from
  scratch, reconcile old-path issues as abandoned rather than lost)* — rejected: this is exactly the kind
  of "live local-store migration/switchover semantics" the review asked to avoid introducing; restart-only
  is the smallest behavior that avoids needing it at all.

## R10. Runtime/telemetry field reuse (no rename)

**Decision**: Both integrations populate the existing `codex_*`-prefixed fields in
`Orchestrator.State`'s running-issue map and status/dashboard code (`codex_app_server_pid`,
`codex_input_tokens`/`codex_output_tokens`/`codex_total_tokens`, `last_codex_event`,
`last_codex_message`, `last_codex_timestamp`, `turn_count`, `codex_totals`, `codex_rate_limits`) rather
than introducing integration-neutral field names.

**Rationale**: ~74 references to these field names span `orchestrator.ex`, `status_dashboard.ex`, and
`presenter.ex`. IV-004 requires common lifecycle/session observability across integrations but
explicitly does not require identical telemetry *shape*; Constitution Principle II (Minimize Fork Delta)
weighs against a rename sweep across three files and their tests for a purely cosmetic improvement. This
is recorded as a conscious, reversible naming choice, not an oversight — a future rename remains open if
a third integration makes the Codex-specific naming genuinely confusing.

## R11. Local tracker `dispatchable` semantics (no invented "archived"/"withdrawn" concept)

**Decision (corrected)**: The local tracker's `IssueRecord` normalizes `dispatchable: true`
unconditionally on every record — there is no `archived`/`withdrawn` field, no operator/tool mechanism to
set one, and no plan to add one.

**Prior plan's gap**: the original data-model.md described `dispatchable` as "`true` unless the
operator/tool explicitly sets an `archived`/withdrawn record" without the on-disk schema anywhere in the
same document defining an `archived` field or any mutation path that could set it — an undefined
provider-side eligibility concept referenced but never specified.

**Rationale/evidence**: Confirmed by reading every adapter's actual `dispatchable` computation
(`gitlab/client.ex:198`, `github/client.ex:199`, `asana/client.ex:223`, `linear/client.ex:484,496-500`,
`jira/client.ex:254,337-347`) that `dispatchable` is not a uniform "is this archived" flag anywhere in
the current codebase — it is each adapter's own encoding of *structural* eligibility particular to that
provider's data shape: GitHub excludes pull requests (`not Map.has_key?(issue, "pull_request")`), Asana
excludes sections and completed tasks, Linear/Jira fold in assignee-filtering and blocked-before-dispatch
gating. **GitLab has no structural exclusion need and hardcodes `dispatchable: true` unconditionally**
(`gitlab/client.ex:198`) — this is the exact, already-existing precedent for the local tracker, which
likewise has no PR/section/completed-task-shaped structural category to exclude (every record in the
local store is, by construction, "a real work item"). Separately confirmed: no `archived`/`withdrawn`/
`soft_delete` concept exists anywhere in the codebase (verified by grep across `lib/symphony_elixir/`),
and the gating the local `IssueRecord` genuinely needs — "should this record currently be worked" — is
already fully covered by two mechanisms this data model already has: `state` (matched against
`tracker.active_states`/`terminal_states`, exactly like every adapter) and `blocked_by`, which the
orchestrator already reads directly and independently of `dispatchable`
(`orchestrator.ex:930`'s stale-dispatch-after-refresh check). If an operator wants to stop Symphony from
touching a local-tracker record, the existing, uniform lever every other adapter already exposes is to
move it to a terminal state — no new mechanism is needed or justified.

**Alternatives considered**:
- *Add an `archived` boolean field with an operator-facing toggle* — rejected: this is inventing local
  lifecycle functionality merely to populate a field description that never needed to say anything other
  than "always true," which the review's own guidance explicitly warns against ("prefer not to invent
  one" absent a concrete inherited requirement — none was found).
- *Derive `dispatchable` from some other local-only heuristic (e.g. record age, last-touched timestamp)*
  — rejected: no requirement (FR/SC) motivates it, and it would silently exclude legitimate work items
  for reasons an operator did not ask for, unlike every other adapter's `dispatchable` rule, which encodes
  an actual structural fact about the provider's data (not a policy the local tracker has any basis to
  invent on Symphony's behalf).

## R5/R7 Addendum (2026-08-25): T016 live CLI verification (installed v2.1.246)

**Scope**: T016's implementation-time verification of the CLI flags and stream-json event-type names
R5/R7/R8 flagged as not yet exercised against a live run. Performed via `claude --help` on the installed
CLI (v2.1.246 — one patch ahead of the v2.1.245 the prior planning pass used; no flag differences observed
for the items below) plus one real `claude -p` turn.

**All six previously-flagged flags reconfirmed present with the documented semantics, unchanged from the
prior pass's `--help` reading**: `--session-id <uuid>` ("Use a specific session ID for the conversation
(must be a valid UUID)"), `--resume [value]` / `-r` ("Resume a conversation by session ID, or open
interactive picker with optional search term"), `--output-format stream-json` (one of `text`/`json`/
`stream-json`), `--verbose`, `--include-partial-messages` (gated to `--print` + `stream-json`),
`--permission-mode bypassPermissions` (one of the documented six-value enum), `--bare` (auth strictly
`ANTHROPIC_API_KEY`/`apiKeyHelper`; OAuth/keychain never read), `--strict-mcp-config` ("Only use MCP
servers from `--mcp-config`, ignoring all other MCP configurations"). No corrections needed to R5/R8's
existing text.

**Live turn**: `claude -p "Reply with exactly the word: pong" --session-id <uuid> --output-format
stream-json --verbose --include-partial-messages --permission-mode bypassPermissions --strict-mcp-config
--no-session-persistence`, run in a scratch directory outside this repo. **Not** run with `--bare`, because
the verification environment authenticates via the caller's existing Claude subscription session
(`"apiKeySource":"none"` in the captured `system/init` event), not a standalone `ANTHROPIC_API_KEY` —
`--bare` would have failed auth in that environment per its own documented behavior. This is a limitation
of the verification environment, not a finding about production behavior; Symphony's actual launches
(which always pass `--bare` per R5/R8) are expected to additionally skip the `hook_started`/`hook_response`
system-subtype events seen below, since `--bare`'s documented scope explicitly includes "skip hooks" and
those events are traced to the verification caller's own user-level `SessionStart` hooks, not anything
Claude Code emits unconditionally.

**Captured top-level `"type"` values** (this is the actual event-name answer R5's confidence note asked
for), in emission order for one no-tool-use turn:

1. `system` (subtype `hook_started` / `hook_response`, one pair per configured `SessionStart` hook —
   verification-environment artifact per above, not expected under `--bare`)
2. `system` (subtype `init`) — the session-start signal: carries `session_id`, `cwd`, `tools`,
   `mcp_servers`, `model`, `permissionMode`, `apiKeySource`, `claude_code_version`, among others. This is
   the natural analogue of Codex's session-start signal and the event T022's `on_message` should treat as
   `session_started`.
3. `system` (subtype `status`, `"status":"requesting"`) — turn-in-progress marker.
4. `stream_event` (repeated) — wraps the raw Anthropic Messages API streaming events verbatim in an
   `event` field: observed `message_start`, `content_block_start`, `content_block_delta` (with
   `delta.type:"text_delta"`), `content_block_stop`, `message_delta`, `message_stop`. This confirms R5's
   assumption that Claude Code's stream-json transport is "one JSON object per line" and additionally shows
   the streaming payload is the *unmodified* Anthropic Messages API stream shape, not a Claude-Code-specific
   re-encoding — useful if `run_turn/4`'s parser wants incremental text deltas.
5. `assistant` — one per complete assistant message, carrying the full non-streaming `message` object
   (role/content/usage). Redundant with the `stream_event` deltas for text-only turns; gives the complete
   message in one event without reassembling deltas.
6. `rate_limit_event` — rate-limit/usage-window status, unrelated to turn outcome.
7. `result` — **the terminal per-turn outcome event** (the direct analogue of Codex's `turn/completed`/
   `turn/failed` R5's confidence note asked about): `{"type":"result","subtype":"success","is_error":false,
   "result":"<final text>","session_id":...,"usage":...,"total_cost_usd":...,"num_turns":...,
   "stop_reason":"end_turn","duration_ms":...,"duration_api_ms":...,"permission_denials":[],
   "terminal_reason":"completed",...}`. `is_error`/`subtype` together encode success vs. failure; this is
   the single event `run_turn/4`'s parser should key off to resolve `{:ok, turn_result}`.

**Confirms R7's core mechanism**: the caller-supplied `--session-id` UUID is echoed back unchanged on every
single event (`system/init`, every `stream_event`, `assistant`, `result`) — Symphony can generate and rely
on its own session UUID up front exactly as R7 decided, with nothing to learn reactively from turn 1's
output.

**Still open / not exercised by this pass** (narrower than before, but not fully closed):
- **`--resume <uuid>` turn-to-turn continuation** (R7's confidence note) was not exercised — only one
  `--session-id` turn was run, no follow-up `--resume` turn. Turn 1's session-identity mechanism is now
  confirmed; the turn-2+ resume path is not.
- **Tool-call event shapes** (a `tool_use` content block / its `stream_event` deltas, and however a tool
  result is threaded back as a `user`-role message) were not observed, because this verification prompt
  intentionally triggered no tool use. T020/T021/T022's MCP tool-call path will need this captured against
  a turn that actually invokes a tool — deferred to that implementation work rather than guessed here.
- **Failure-path `result` shape** (`is_error:true` / a non-`"success"` `subtype`) was not observed, since
  the one live turn succeeded. The field names above (`is_error`, `subtype`) are confirmed to exist on the
  terminal event; their failure-case values are not.

No other planning artifact was changed by this addendum, per T016's scope.

## R6/R6a/R7 Addendum (2026-08-26): T022/T023 live CLI + real MCP-tool-call verification (installed v2.1.246)

**Scope**: T022's mandatory pre-completion smoke verification — the previous addendum's live turn triggered
no tool use, so the MCP tool-call path (T020/T021's own module, exercised for real through T022's actual
`ClaudeCode.AppServer`-shaped wiring) and `--resume` continuation were still unobserved. This pass ran two
non-committed scratch scripts (not part of the test suite, not committed) against the real installed CLI:
(1) a real `SymphonyElixir.ClaudeCode.MCPServer` bound to a real, established `Local.Store`/`Local.Adapter`
tracker with one seeded issue, a real `--mcp-config` file pointing at it, and one `claude -p` turn instructed
to call `local_tracker_set_state`; (2) a follow-up `claude --resume <same-uuid>` turn against the same
session id (no MCP config needed for this one — its only purpose was observing resume continuity).

**Tool-call path fully confirmed working end to end, for real** — not simulated: the live `claude` process
made a real MCP HTTP call to Symphony's own `ClaudeCode.MCPServer`/`Tracker.execute_bound_agent_tool/4`/
`Local.AgentTool`/`Local.Store` chain, and the target issue's `state` was independently re-read via
`Local.Adapter.fetch_issues_by_ids/1` afterward and confirmed changed from `"todo"` to `"done"` — proof the
call landed on real state, not just that the CLI printed something. This validates R6/R6a's central
architectural bet (MCP tool calls are an out-of-band HTTP channel entirely independent of the `stream-json`
stdout stream) with a real tool invocation, not just the no-tool-use turn the prior addendum had.

**`--resume <uuid>` continuation confirmed** (closes R7's last open item): a second `claude` process launched
with `--resume <same session_id>` (no `--session-id`) echoed the identical `session_id` on every event
(`system/init` included — a resumed turn still emits `system/init`, contrary to a plausible guess that it
might not) and correctly retained conversational context (asked to "reply with exactly: RESUMED", it did,
proving the resumed turn saw the first turn's history). No corrections needed to T022's implementation, which
already treats `system/init` identically regardless of first-turn-vs-resume.

**New real event shapes observed, none requiring a parser change** (`ClaudeCode.AppServer`'s `run_turn/4`
already tolerates every one of these via its generic `%{"type" => type}` fallback branch, which forwards an
unrecognized-but-well-formed event as a `:notification` and keeps reading — confirmed by this run producing
zero parser errors/crashes end to end):

- `system` subtype `status` recurs multiple times per turn (once per model round-trip, not once at start as
  the prior addendum's simpler no-tool-use turn suggested).
- `system` subtype `thinking_tokens` — new, appears during extended-thinking generation; not previously
  observed since the prior verification prompt did not trigger visible thinking.
- A new top-level `"type": "user"` event — Claude Code's synthetic representation of an MCP tool's result
  fed back into the model's own context, shaped as `{"type":"user","message":{"role":"user","content":
  [{"type":"tool_result","tool_use_id":...,"content":[...]}]},"tool_use_result":...}`. Two shapes of this
  were observed in one run: one whose `content` was a client-side `tool_reference`/tool-selection artifact
  (`{"type":"tool_reference","tool_name":"mcp__symphony_tracker__local_tracker_set_state"}` — Claude Code
  appears to resolve an MCP tool by name via an internal deferred-tool-selection step before the real
  `tool_use` call, mechanically analogous to this very session's own `ToolSearch` deferred-tool pattern, but
  this is entirely internal to the CLI/model loop and never reaches Symphony's MCP server as a distinct wire
  call), and one whose `content` carried the tool's real return value (the exact JSON
  `Local.AgentTool.execute_agent_tool/3` returns, e.g. `{"state":"done","updated_at":"..."}` as a `text`
  content block) — confirming the tool's actual output round-trips back to the model unmodified.
- `stream_event` wrapping `content_block_start` with `content_block.type: "tool_use"` — the streaming
  representation of the model deciding to call a tool. Confirmed present, and confirmed **not needed** by
  `run_turn/4`: the tool call itself is fully resolved by the MCP HTTP round trip (T020/T021's own module),
  never by anything read off the `stream-json` stdout Port.
- The terminal `result` event's exact shape was re-confirmed unchanged from the prior addendum:
  `is_error: false`, `subtype: "success"`, `result: "<the literal final-turn text}"`, `session_id`, plus a
  large amount of additional cost/usage/telemetry detail (`usage`, `modelUsage`, `total_cost_usd`,
  `subagent_stats`, etc.) that `ClaudeCode.AppServer` does not currently read (kept as the full raw payload
  under `turn_result.raw`/the `:turn_completed` message's `raw` field for any future consumer, not parsed
  field-by-field, matching the "small parsing functions" / "don't parse what isn't needed yet" guidance).

**New, non-blocking observation (latency, not correctness)**: the installed CLI prints (to its own stderr,
confirmed distinct from the `stream-json` stdout Symphony reads) `"Warning: no stdin data received in 3s,
proceeding without it"` when launched with an open-but-unused stdin pipe — which is exactly how `Port.open/2`
leaves stdin by default when the caller never writes to or closes it, as `ClaudeCode.AppServer.run_turn/4`
does today. This adds a fixed ~3s delay to every real turn's startup and is unrelated to `-p`'s own prompt
argument (already passed positionally, not via stdin) — it appears to be a generic "wait briefly in case a
caller pipes additional prompt content" heuristic. Not fixed in this session: closing/redirecting a `Port`'s
stdin independently of the whole port has no portable, non-shell-string mechanism in vanilla Erlang, and a
~3s fixed cost is a rounding error against a real coding-agent turn's overall runtime (T022/T023's own scope
is correctness, not this class of latency micro-optimization) — flagged here for T027+ to reconsider if it
ever becomes material (e.g. `< /dev/null` if a structured-argv-preserving redirect approach is found).

**Still open / not exercised by this pass** (unchanged from the prior addendum, and not attempted here per
the explicit "do not fake certainty" instruction — inducing a genuine `is_error:true` terminal event would
require either a real model/API failure or a permission-mode change away from `bypassPermissions`, neither
of which is safe or deterministic to manufacture in a live smoke check): the failure-path `result` shape
(`is_error:true`) remains fixture-only, covered only by `claude_code_app_server_test.exs`'s synthetic
`:failure_result`/`:malformed_result` fixtures, not the real CLI.

No other planning artifact was changed by this addendum, per T022/T023's scope.

## Repair Addendum (2026-08-26): T022/T023 adversarial-review repair

**Scope**: an independent adversarial review of commit `918f845` (T022/T023) found one BLOCKING and two
MAJOR findings, plus several MINOR/NOTE items. This addendum records the repair, still scoped to T022/T023
only — no T027+ work was started or touched.

**1. First-turn/resume state machine (BLOCKING, fixed).** `run_turn/4` previously flipped its `:atomics`
first-turn flag unconditionally at call entry, before confirming the launch or the CLI ever established a
session. A launch/bootstrap failure (missing executable, process crash or timeout before `system/init`)
left the flag permanently flipped, so any retry of `run_turn/4` on the *same* session would incorrectly
launch with `--resume <uuid>` against a session the CLI never created. Not reachable via any current
production caller (`AgentRunner` never retries `run_turn/4` on the same session; the Orchestrator always
retries via a brand-new `AgentRunner.run/3` call, which gets a brand-new session and a fresh atomics ref),
but a real, provable defect that any future same-session retry logic would trigger silently. Fixed: the
`:atomics.exchange/3` claim at entry is now provisional — it is reverted back to 0 (`revert_unestablished_claim/3`)
whenever the call that made the claim never observed `system/init` (tracked via the receive loop's own
`:bootstrap`/`:turn` phase, now returned alongside the outcome), and only that claiming call is ever allowed
to revert it, so a later turn's own failure on an *already-established* session never re-arms
`--session-id`. This also required fixing a second, closely-related bug uncovered while implementing the
fix: `handle_incoming/5` previously hardcoded the *next* phase to `:turn` on every branch except the
literal `system/init` line — meaning any pre-init noise (a stray non-JSON line, an out-of-order `system`
event) silently ended the bootstrap-phase timeout window before `system/init` had actually been seen. Now
`phase` is threaded through unchanged except on the actual `system/init` transition. Four new regression
tests in `claude_code_app_server_test.exs` (describe block "run_turn/4 first-turn/resume revert
semantics") cover: crash before init, timeout before init, executable-not-found before init (all three
prove a same-session retry still uses `--session-id`), and a turn that fails *after* init (proving a retry
correctly still uses `--resume`, i.e. the fix does not over-revert).

**2. Coverage exclusion (MAJOR, addressed).** The review found `validate_workspace_cwd/1`'s duplicated
branches and the partial-start cleanup paths (`write_mcp_config/2` failure after listener start,
`MCPServer.start_link/1` failure) had zero test coverage anywhere, hidden by the module-wide
`ignore_modules` entry — unlike the identical logic in `Codex.AppServer`, which its own test suite already
exercises directly. Repaired by adding: three workspace-boundary tests (workspace root itself, a path
outside the workspace root, a symlink escape), mirroring `app_server_test.exs`'s existing Codex precedent
exactly; and two partial-start cleanup tests (an MCP listener bind failure via a deterministic port
collision, and a `--mcp-config` write failure via an unwritable directory, the latter proving the
just-started listener was actually stopped by rebinding the same port afterward). Two small,
purely-additive test-injection seams were added to `start_session/2`'s `opts` to make these deterministic:
`opts[:mcp_start_opts]` (forwarded into `MCPServer.start_link/1`, e.g. to force a `:port` collision) and
`opts[:mcp_config_dir]` (overrides where the `--mcp-config` temp file is written, e.g. to an unwritable
directory) — both default to today's production behavior when omitted and are not part of the documented
public `start_session/2` contract. The module-wide `ignore_modules` entry is **retained** (see `mix.exs`'s
own comment there): the module still contains genuinely nondeterministic-to-hit Port/OS-process branches
(e.g. `close_port/1`'s `:erlang.port_info/1 == :undefined` race, `kill_os_process/1`'s rescue clauses) that
these new tests do not attempt to force. This was a reassessed decision, not the original commit's
precedent accepted at face value.

**3. `claude_code.command` parsing semantics (MAJOR, documented, behavior retained).** The review found
`claude_code.command` is parsed as a naive whitespace-split argv list while `codex.command` is a genuine
shell command line (interpolated into `bash -lc`), despite both being documented as "same shape class."
Decision: **retain** direct-executable-spawning + whitespace-split argv (no repository evidence favors
switching to a shell wrapper, and the current approach removes any shell-injection surface entirely) but
make the contract explicit rather than silently ambiguous. Documented in
`contracts/workflow-config-fields.md` and in `ClaudeCode.AppServer.resolve_command/0`'s own doc comment;
pinned down with two new tests ("run_turn/4 claude_code.command parsing contract") proving both the
supported case (appending extra whitespace-separated flags) and the explicitly-unsupported case (shell
quoting is not honored — quote characters end up as literal, split argv content).

**4. `opts[:issue]` contract documentation (MINOR, fixed).** `contracts/coding-agent-behaviour.md`'s
`start_session/2` Input section documented `opts` as "at minimum `worker_host`" without ever mentioning
`:issue`, even though `ClaudeCode.AppServer.start_session/2` already required it. Confirmed this was a
documentation gap, not an architectural violation: `Codex.AppServer.start_session/2` only reads
`opts[:worker_host]` and ignores unrecognized keys, so passing `issue: issue` unconditionally (regardless
of which concrete `CodingAgent` module is active) is harmless to Codex and does not require
provider-aware branching in any caller. The contract doc now says so explicitly.

**Constraints this repair leaves for T027 (unchanged from the original review, restated for the record):**
- T027 must pass `issue: issue` into `start_session/2`'s opts unconditionally when resolving the concrete
  `CodingAgent` module — `issue` is already in lexical scope at `agent_runner.ex`'s only `start_session/2`
  call site (`run_codex_turns/5`), so this is a small, mechanical addition, not a redesign.
- The Orchestrator's stall-timeout watchdog (`orchestrator.ex:582`) reads `Config.settings!().codex.stall_timeout_ms`
  unconditionally — there is no `claude_code.stall_timeout_ms` field. Once T027 wires dispatch, a
  Claude-Code-backed run's stall watchdog will silently be governed by the *Codex* config value regardless
  of `agent_execution.kind`. Not fixed here (explicitly out of scope for this repair — no
  provider-aware orchestrator stall-timeout selection was implemented); T027 (or an explicit follow-up
  task) must decide whether that shared knob is acceptable or needs its own `claude_code.stall_timeout_ms`
  field plus a kind-aware lookup.
- The ~3s CLI stdin-wait latency (documented in the R6/R6a/R7 addendum above) was left as-is per this
  repair's explicit scope — it is a latency note, not a correctness defect, and expanding this repair
  around it was out of scope.

No T027 (or later) production code was touched by this repair.

## R8 Correction Addendum (2026-08-26): scoped local execution model supersedes `--bare` as the default

**Scope**: two investigation-only sessions (not implementation sessions) re-examined R8's default
auth/isolation choice against primary evidence — the installed CLI's own `--help`/`--setting-sources`
semantics, `code.claude.com` documentation, and live, non-destructive experiments against the real,
native `claude` binary (not this development sandbox's `cmux`-shimmed `claude` on `PATH`, which proxies
back into the live session and is not production-representative). This addendum corrects R8's **default
command choice only** — R8's other findings (`--permission-mode bypassPermissions`'s correctness, the
`OPENAI_API_KEY`/Codex-credential-exclusion pattern, `--strict-mcp-config`'s role) remain correct and
unchanged. This is a correction, not a claim that T022/T023 knew this at the time; the production repair
this addendum authorizes is tracked as its own task, T028A (tasks.md), not folded into T022/T023's
history.

**1. `--bare` forces API-key-only auth and cannot be relaxed in place (confirmed, not new).** Verbatim
from the installed CLI's own `--help`: `--bare` — "Anthropic auth is strictly `ANTHROPIC_API_KEY` or
`apiKeyHelper` via `--settings` (OAuth and keychain are never read)." This is exactly what R8 already
documented; it is restated here only because it is the reason T029 (tasks.md) has been blocked on
`ANTHROPIC_API_KEY` availability rather than able to use an already-authenticated Claude subscription.

**2. `--safe-mode` is not the fix — it is scope-blind, not scope-aware.** The first investigation session
initially proposed `--safe-mode` (which does not force API-key auth: "Authentication, model selection,
built-in tools, and permissions work normally... which differs from `--bare`") as a way to unblock
subscription/OAuth auth. Confirmed via the CLI's own full flag description that this was the wrong
mechanism for what Symphony's local execution model actually wants: `--safe-mode` "Start[s] with all
customizations disabled... CLAUDE.md, skills, plugins, hooks, MCP servers, custom commands and agents,
output styles, workflows, custom themes, custom keybindings, status line and file-suggestion commands, LSP
servers, and auto memory do not load" — an all-or-nothing kill switch with no repo-vs-user distinction.
Empirically confirmed this also disables the workspace's own `.mcp.json` and any project-scoped hooks, not
just ambient/user-global ones — exactly the repository-owned context Symphony's local execution model
wants to *keep*.

**3. `--setting-sources <user,project,local>` is the actual scope-aware mechanism.** This flag controls
which settings-file scope(s) load: `~/.claude/settings.json` (`user`), `.claude/settings.json`
(`project`, the file a repository commits and shares with its team), and `.claude/settings.local.json`
(`local`, personal-but-per-repo, gitignored). Per `code.claude.com/docs/en/mcp`: excluding `project` from
`--setting-sources` is the documented way to keep a project's own `.mcp.json` from loading at all — the
same mechanism generalizes, in the opposite direction, to excluding `user` while keeping `project`/`local`.
Per `code.claude.com/docs/en/permissions`' "What runs before you trust a folder" table: in `claude -p`
(headless — Symphony's exact invocation mode) with the folder never trusted (headless mode never shows the
interactive trust dialog at all), **project-scoped hooks are "Used" unconditionally** and **project
`.mcp.json` servers are "Connected without asking, approved or not."** Repository-owned hooks and MCP
already work headlessly today with zero special flags; the piece that needed active suppression was
user-global config, not repository config — `--setting-sources` is exactly that suppression knob, and it
does not touch `--strict-mcp-config`, the environment allow-list, or `--permission-mode`.

**4. Empirically verified end to end**, against the real native `claude` binary, with Symphony's exact
`claude_subprocess_env/0` allow-list (`PATH HOME USER SHELL LANG LC_ALL LC_CTYPE TERM TMPDIR
ANTHROPIC_API_KEY`), with `ANTHROPIC_API_KEY` unset, using normal auth mode (no `--bare`, no
`--safe-mode`) plus `--setting-sources project,local --strict-mcp-config --mcp-config <two explicit
files>`, in one combined run:
   - A scratch repo's own `CLAUDE.md` loaded (the model echoed a planted marker phrase) while the real
     ambient `~/.claude/CLAUDE.md` did not leak (a targeted recall probe, not `system/init` metadata,
     answered NO).
   - A scratch repo-scoped `SessionStart` hook fired (a marker file was created on disk) while a real
     ambient plugin hook (observed firing under plain normal-mode with no `--setting-sources` in an
     earlier probe in the same investigation) did not fire (empty stderr).
   - `system/init`'s `mcp_servers` field listed both a repo-scoped probe server (from the scratch repo's
     own `.mcp.json`) and a Symphony-style explicit server (from a second, separately-named
     `--mcp-config` file) as attempted, while a real ambient user-scope MCP server already configured on
     the test machine never appeared.
   - Installed marketplace plugin enumeration dropped from the real set of installed plugins (visible
     under both plain normal-mode and `--safe-mode`) to empty.
   - `apiKeySource` stayed `"none"` throughout, and a real `--session-id` then `--resume` pair correctly
     preserved conversation context (a planted word was recalled) — proving this composes with Symphony's
     real per-turn relaunch pattern (research.md R7), non-interactively, with no TTY.

**5. MCP composition: `--strict-mcp-config` is not weakened.** `--strict-mcp-config`'s own documented
behavior ("Only use MCP servers from `--mcp-config`, ignoring all other MCP configurations") does not
carve out project `.mcp.json` — dropping it to admit repo MCP was never necessary or considered. Instead,
`--mcp-config` itself accepts multiple space-separated files in one invocation (confirmed against the
installed CLI in the same experiment above): Symphony's own generated per-run MCP config and the
workspace's own `.mcp.json` (when present) are both passed to the *same* `--mcp-config` invocation, so
`--strict-mcp-config` continues to exclude every other (ambient/user-global) MCP source untouched.

**Decision (supersedes R8's default only)**: `claude_code.command`'s schema default changes from
`claude --bare --permission-mode bypassPermissions --strict-mcp-config` to
`claude --setting-sources project,local --permission-mode bypassPermissions --strict-mcp-config`.
`ClaudeCode.AppServer` additionally composes the workspace's own `.mcp.json` (when present at the
workspace root — the per-issue workspace is a checkout of the target repository, never the source repo
itself, per contracts/coding-agent-behaviour.md) into the same `--mcp-config` invocation as Symphony's own
generated config. `--bare` remains fully available as an explicit operator override in `claude_code.command`
for deployments that want the strictest, config-blind, API-key-only isolation instead — this addendum
changes the *default*, not the CLI's supported flag surface. Tracked as tasks.md T028A, inserted before
T029 (which T029 now depends on) — see contracts/workflow-config-fields.md for the corresponding contract
update.

**Trust-boundary implication, stated explicitly (not previously written down anywhere in this feature's
planning artifacts)**: because headless mode never shows a trust dialog, any hook or `.mcp.json` server
committed to a repository's `.claude/settings.json`/`.mcp.json` executes/connects unconditionally the
first time Symphony dispatches a `claude_code` turn against that workspace — there is no approval step to
opt out of. This is consistent with Symphony's own existing trust boundary (it already executes arbitrary
repository code via the coding agent, by design) but is a materially different exposure than `--bare`'s
total silence on repository content, and is why this addendum documents it explicitly rather than treating
it as an implementation detail.

**What this addendum does not change**: the `OPENAI_API_KEY`/Codex-credential exclusion pattern
(`claude_subprocess_env/0`'s allow-list, untouched), `--permission-mode bypassPermissions`,
`--strict-mcp-config` itself, the direct-executable/no-shell/whitespace-argv `claude_code.command` parsing
model (Repair Addendum above, unchanged), and repository subagents/`@skills-dir` plugins remain
**not** loaded in headless mode regardless of trust (per the same "What runs before you trust a folder"
table) — this addendum does not claim otherwise and no work in T028A attempts to change that.

**Review correction (2026-08-26): `--mcp-config` composition order.** An independent review of T028A found
that `mcp_config_args/2` originally ordered Symphony's own generated config *before* the repo's `.mcp.json`
in the single `--mcp-config` invocation. Empirically verified against the installed CLI: when two
`--mcp-config` inputs define an MCP server under the same name, the *later* one wins. Under the original
order, a repository-controlled `.mcp.json` declaring its own server named `symphony_tracker` would
therefore silently shadow Symphony's real tracker server — a collision resolved entirely inside the CLI's
own config merge, invisible to Symphony's per-run bearer-token check. Fixed by reordering
`mcp_config_args/2` to `[repo, generated]`: repository MCP configuration may contribute additional MCP
servers, but it can no longer override Symphony-owned MCP server identities, because Symphony's generated
config is always supplied last. No other part of R8's Correction Addendum changes — `symphony_tracker`
keeps its stable, non-randomized name; `--strict-mcp-config`, `--setting-sources project,local`, and the
rest of the local execution trust model are unaffected.
