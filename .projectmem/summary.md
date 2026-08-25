# projectmem - symphony

_Last updated: 2026-08-25_

## Project purpose
Replace this placeholder with a concise description of what this project does, who it serves, and the main technologies or runtime assumptions.

## Recent issues
- [DONE] #legacy_678e Legacy issue: Add GitLab Issues tracker adapter -> Add GitLab Issues tracker adapter (fixed)
- [DONE] #legacy_633e Legacy issue: feat(jira): honor blocking issue links (#108) -> feat(jira): honor blocking issue links (#108) (fixed)
- [DONE] #legacy_2121 Legacy issue: Fix Burrito release tag verification -> Fix Burrito release tag verification (fixed)
- [DONE] #legacy_1f32 Legacy issue: Gate Jira new-category issues on blockers -> Gate Jira new-category issues on blockers (fixed)
- [DONE] #legacy_044f Legacy issue: Add GitHub Issues tracker adapter -> Add GitHub Issues tracker adapter (fixed)

## Decisions
- Bootstrap session (2026-08-25): initialized projectmem and Spec Kit (--integration claude) in this existing repo on branch development. DEVELOPMENT_SPEC intentionally left absent -- no spec content was written this session. Next session should begin the Spec Kit lifecycle (/speckit-constitution, /speckit-specify, etc.) to originate specification content, including for the SQLite tracker and Claude Code worker work ported from the Bindle prototype.

## Notes
- Add generic tracker interface with Linear adapter (#102)
- Add Jira Cloud tracker adapter
- Add Asana tracker adapter
- Make terminal workspace cleanup safe
- Keep retry dispatch fresh without leaking claims
- Retry failed workspace setup and anchor local roots
- Block generic tool input and document idle timeouts
- Bump Symphony version to 0.0.2
- Add Symphony release skill
- Scrub GitHub and GitLab authentication token aliases (#119)

## Key files
- `elixir/lib/symphony_elixir/config.ex`
- `elixir/lib/symphony_elixir/workflow_store.ex`
- `elixir/test/symphony_elixir/core_test.exs`
- `elixir/test/symphony_elixir/extensions_test.exs`
- `elixir/lib/symphony_elixir.ex`
- `elixir/lib/symphony_elixir/agent_runtime_supervisor.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/test/symphony_elixir/live_e2e_test.exs`
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- `elixir/config/config.exs`
- `elixir/lib/symphony_elixir/config/schema.ex`
- `elixir/test/fixtures/startup_workflow.md`
- `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- `elixir/AGENTS.md`
- `.github/workflows/burrito-release.yml`
- `elixir/.gitignore`
- `elixir/README.md`
- `elixir/lib/symphony_elixir/cli.ex`
- `elixir/mix.exs`
- `elixir/mix.lock`

## Open questions
- None logged yet.
