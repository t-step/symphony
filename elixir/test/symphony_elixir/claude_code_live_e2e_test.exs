defmodule SymphonyElixir.ClaudeCodeLiveE2ETest do
  @moduledoc """
  Flag-gated live end-to-end test proving the `agent_execution.kind: claude_code` path works
  through Symphony's ordinary `AgentRunner` dispatch boundary against the real, installed `claude`
  CLI (tasks.md T029, spec SC-002). Mirrors `live_e2e_test.exs`'s gating convention
  (`SYMPHONY_RUN_LIVE_E2E=1` opt-in, `@tag skip: ...` when absent) but exercises the local,
  file-backed tracker instead of a real Linear workspace, so the acceptance signal — the local
  tracker record's `state` actually changing on disk — can be observed independently of anything
  Claude itself reports, via one real MCP tool call over `ClaudeCode.MCPServer` (research.md R6a).
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Local.Init, as: LocalInit

  @moduletag :live_e2e
  @moduletag timeout: 300_000

  @issue_id "claude-live-e2e-1"
  @live_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1",
                          do: "set SYMPHONY_RUN_LIVE_E2E=1 to enable the real Claude Code end-to-end test"
                        )

  @tag skip: @live_e2e_skip_reason
  test "a claude_code-backed local-tracker work item reaches a terminal state via real AgentRunner dispatch" do
    require_claude_executable!()
    require_claude_authenticated!()

    run_id = "symphony-claude-live-e2e-#{System.unique_integer([:positive])}"
    test_root = Path.join(System.tmp_dir!(), run_id)
    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    data_path = Path.join(test_root, "local_tracker.db")
    original_workflow_path = Workflow.workflow_file_path()

    File.mkdir_p!(workflow_root)

    try do
      assert {:ok, :initialized} = LocalInit.run(data_path)
      seed_dispatchable_issue!(data_path)

      write_local_claude_workflow!(workflow_file, data_path, test_root)
      Workflow.set_workflow_file_path(workflow_file)
      restart_workflow_store!()

      # Confirms the structural (restart-only) selectors actually pinned to this run's
      # configuration before dispatching through them (IV-005).
      assert Config.structural_settings!().tracker_kind == "local"
      assert Config.structural_settings!().agent_execution_kind == "claude_code"

      assert {:ok, [%Issue{state: "todo"} = issue]} = Tracker.fetch_issues_by_ids([@issue_id])

      # The ordinary Symphony dispatch path: AgentRunner resolves CodingAgent.resolve/0 ->
      # ClaudeCode.AppServer, starts the per-run MCP listener, launches the real `claude` CLI
      # subprocess per turn, and tears both down in an `after` block on every exit path.
      assert :ok = AgentRunner.run(issue, self(), max_turns: 3)

      lifecycle_events = drain_lifecycle_events(@issue_id)

      assert Enum.any?(lifecycle_events, &(&1.event == :session_started)),
             "expected a session_started lifecycle event (same class Codex reports), got: #{inspect(lifecycle_events)}"

      assert Enum.any?(lifecycle_events, &(&1.event == :turn_completed)),
             "expected a turn_completed terminal lifecycle event (same class Codex reports), got: #{inspect(lifecycle_events)}"

      refute Enum.any?(lifecycle_events, &(&1.event == :turn_failed)),
             "did not expect a turn_failed event: #{inspect(lifecycle_events)}"

      # Independently-observable system effect: read the local tracker record directly off disk,
      # not from anything Claude said it did. This is the real proof the MCP tool-call channel
      # (claude -> ClaudeCode.MCPServer -> Tracker.execute_bound_agent_tool/4 -> Local.Store) works
      # end to end through the real CLI, not merely that Claude emitted success-shaped text.
      assert {:ok, [%Issue{state: final_state}]} = Tracker.fetch_issues_by_ids([@issue_id])

      assert final_state == "done",
             "expected the local tracker record's state to independently reflect the real MCP " <>
               "tool call, got: #{inspect(final_state)}"
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(test_root)
    end
  end

  defp require_claude_executable! do
    if is_nil(System.find_executable("claude")) do
      flunk("live e2e requires the `claude` CLI on PATH")
    end
  end

  # T028A repaired claude_code.command's default to `--setting-sources project,local` (dropping
  # `--bare`), so the real installed CLI now authenticates via the operator's existing Claude
  # subscription/OAuth login instead of requiring ANTHROPIC_API_KEY (contracts/workflow-config-
  # fields.md's "Local execution trust model" section). `claude auth status --json` reports that
  # login state directly (loggedIn/authMethod), without spending a model turn, so it is the
  # correct prerequisite gate for this configuration.
  defp require_claude_authenticated! do
    claude = System.find_executable("claude")

    case System.cmd(claude, ["auth", "status", "--json"], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"loggedIn" => true}} ->
            :ok

          {:ok, status} ->
            flunk(
              "live e2e requires the installed claude CLI to be authenticated via subscription/OAuth " <>
                "login (claude_code.command's default now uses --setting-sources project,local, not " <>
                "--bare/ANTHROPIC_API_KEY, per T028A) -- run `claude auth login`. `claude auth status " <>
                "--json` reported: #{inspect(status)}"
            )

          {:error, reason} ->
            flunk("live e2e could not parse `claude auth status --json` output: #{inspect(reason)}, got: #{output}")
        end

      {output, status} ->
        flunk("live e2e could not determine claude auth status (exit #{status}): #{output}")
    end
  end

  defp seed_dispatchable_issue!(data_path) do
    seed_local_tracker_issues!(data_path, %{
      @issue_id => %{"state" => "todo", "identifier" => @issue_id, "title" => "Symphony Claude Code live e2e"}
    })
  end

  defp write_local_claude_workflow!(path, data_path, test_root) do
    workspace_root = Path.join(test_root, "workspaces")

    File.write!(
      path,
      """
      ---
      tracker:
        kind: local
        provider:
          path: #{Jason.encode!(data_path)}
        active_states: ["todo", "in_progress"]
        terminal_states: ["done", "cancelled"]
      workspace:
        root: #{Jason.encode!(workspace_root)}
      agent:
        max_concurrent_agents: 1
        max_turns: 3
      agent_execution:
        kind: claude_code
      claude_code:
        read_timeout_ms: 30000
        turn_timeout_ms: 120000
      observability:
        dashboard_enabled: false
      ---
      #{live_prompt()}
      """
    )
  end

  defp live_prompt do
    """
    You are running a real Symphony end-to-end test validating the Claude Code coding-agent
    execution integration.

    Call the `local_tracker_set_state` tool (exposed by the `symphony_tracker` MCP server) exactly
    once, passing state="done".

    Do not ask for approval. Stop as soon as the tool call succeeds; do not make any other tool
    calls or file changes.
    """
  end

  defp drain_lifecycle_events(issue_id), do: drain_lifecycle_events(issue_id, [])

  defp drain_lifecycle_events(issue_id, acc) do
    receive do
      {:worker_runtime_info, ^issue_id, _info} ->
        drain_lifecycle_events(issue_id, acc)

      {:codex_worker_update, ^issue_id, message} ->
        drain_lifecycle_events(issue_id, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
