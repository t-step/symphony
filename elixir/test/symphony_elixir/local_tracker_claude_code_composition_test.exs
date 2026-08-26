defmodule SymphonyElixir.LocalTrackerClaudeCodeCompositionTest do
  @moduledoc """
  Proves User Story 3's composition claim (spec AS1; quickstart.md Scenario 3): a deployment
  configured with only `tracker.kind: local` and `agent_execution.kind: claude_code` dispatches,
  executes, and completes a work item's run-attempt lifecycle using only those two components,
  with no hosted tracker or Codex involvement (tasks.md T031).

  Unlike `claude_code_live_e2e_test.exs` (T029, flag-gated, real installed `claude` CLI + real
  model call), this test drives the Claude Code side through a deterministic `fake-claude` shell
  fixture — mirroring `claude_code_app_server_test.exs`'s established `fake-codex`-style pattern —
  so it is safe and non-flaky for ordinary `mix test`/`make all` runs and does not depend on an
  LLM actually following a natural-language instruction (tasks.md Phase 5 "Testing approach").
  It exercises the real `AgentRunner.run/3` dispatch boundary, the real `Local.Adapter`/`Local.Store`,
  and the real `ClaudeCode.AppServer`/`MCPServer` wiring — only the `claude` executable itself is a
  fixture.

  Also covers T032 (quickstart.md Scenario 2 step 6; research.md R6a): the fake-`claude` fixture
  itself (not the test process) reads the `--mcp-config` file Symphony generated for the run,
  extracts the real ephemeral `symphony_tracker` MCP URL from it, and issues a real HTTP
  `tools/call` for `local_tracker_set_state` against that URL — the same structural path the real
  `claude` CLI's MCP client would take. Mutation is verified by reading
  `.symphony/local_tracker.json` directly off disk, never by trusting the run's reported success.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Local.Init, as: LocalInit

  @issue_id "composition-1"

  setup do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-local-claude-composition-test-#{System.unique_integer([:positive])}")

    data_path = Path.join(test_root, "local_tracker.json")
    workspace_root = Path.join(test_root, "workspaces")
    fake_claude = Path.join(test_root, "fake-claude")

    File.mkdir_p!(test_root)
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(test_root) end)

    %{
      test_root: test_root,
      data_path: data_path,
      workspace_root: workspace_root,
      fake_claude: fake_claude
    }
  end

  test "a claude_code-backed local-tracker work item completes its run-attempt lifecycle via real AgentRunner dispatch",
       %{data_path: data_path, workspace_root: workspace_root, fake_claude: fake_claude} do
    write_fake_claude_two_turn_success!(fake_claude)

    assert {:ok, :initialized} = LocalInit.run(data_path)
    seed_dispatchable_issue!(data_path)

    write_local_claude_workflow!(Workflow.workflow_file_path(), data_path, workspace_root, fake_claude)
    restart_workflow_store!()

    # Confirms the structural (restart-only) selectors actually pinned to this deployment's
    # configuration before dispatching through them (IV-005) -- no hosted tracker, no Codex.
    assert Config.structural_settings!().tracker_kind == "local"
    assert Config.structural_settings!().agent_execution_kind == "claude_code"

    assert {:ok, [%Issue{state: "todo"} = issue]} = Tracker.fetch_issues_by_ids([@issue_id])

    assert :ok = AgentRunner.run(issue, self(), max_turns: 1)

    lifecycle_events = drain_lifecycle_events(@issue_id)

    assert Enum.any?(lifecycle_events, &(&1.event == :session_started)),
           "expected a session_started lifecycle event (same class Codex reports), got: #{inspect(lifecycle_events)}"

    assert Enum.any?(lifecycle_events, &(&1.event == :turn_completed)),
           "expected a turn_completed terminal lifecycle event (same class Codex reports), got: #{inspect(lifecycle_events)}"

    refute Enum.any?(lifecycle_events, &(&1.event == :turn_failed)),
           "did not expect a turn_failed event: #{inspect(lifecycle_events)}"
  end

  test "an MCP local_tracker_set_state tool call issued by the fake-claude fixture lands on the exact bound issue record",
       %{data_path: data_path, workspace_root: workspace_root, fake_claude: fake_claude} do
    write_fake_claude_mcp_tool_call!(fake_claude)

    assert {:ok, :initialized} = LocalInit.run(data_path)
    seed_dispatchable_issue!(data_path)

    write_local_claude_workflow!(Workflow.workflow_file_path(), data_path, workspace_root, fake_claude)
    restart_workflow_store!()

    assert {:ok, [%Issue{state: "todo"} = issue]} = Tracker.fetch_issues_by_ids([@issue_id])

    assert :ok = AgentRunner.run(issue, self(), max_turns: 1)

    lifecycle_events = drain_lifecycle_events(@issue_id)

    assert Enum.any?(lifecycle_events, &(&1.event == :turn_completed)),
           "expected the run to reach a terminal turn_completed lifecycle event, got: #{inspect(lifecycle_events)}"

    # Independent proof of mutation: read the on-disk store directly, not through
    # `Local.Adapter`/`Local.Store` (the same code path the tool call itself used) and not by
    # trusting the run's reported lifecycle events.
    on_disk_record =
      data_path
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["issues", @issue_id])

    assert on_disk_record["state"] == "in_progress",
           "expected the fake-claude fixture's real MCP tools/call to have mutated " <>
             "#{@issue_id}'s on-disk state to in_progress, got record: #{inspect(on_disk_record)}"

    assert on_disk_record["identifier"] == @issue_id
  end

  defp seed_dispatchable_issue!(data_path) do
    File.write!(
      data_path,
      Jason.encode!(%{
        "format_version" => 1,
        "issues" => %{
          @issue_id => %{
            "state" => "todo",
            "identifier" => @issue_id,
            "title" => "Local tracker + Claude Code composition"
          }
        }
      })
    )
  end

  defp write_local_claude_workflow!(path, data_path, workspace_root, fake_claude) do
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
        max_turns: 1
      agent_execution:
        kind: claude_code
      claude_code:
        command: #{Jason.encode!(fake_claude)}
        read_timeout_ms: 5000
        turn_timeout_ms: 10000
      observability:
        dashboard_enabled: false
      ---
      Resolve the assigned work item.
      """
    )
  end

  defp write_fake_claude_two_turn_success!(path) do
    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"composition-fixture"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    """)

    File.chmod!(path, 0o755)
  end

  # Unlike `write_fake_claude_two_turn_success!/1`, this fixture actually plays the MCP client
  # role a real `claude` process would: it locates its own `--mcp-config` argv value (the JSON
  # file `ClaudeCode.AppServer.write_mcp_config/2` generated for this run), extracts the real
  # ephemeral `symphony_tracker` server URL from it (never hardcoded — this is what proves the
  # fixture is driven through the actual generated endpoint, not a stand-in), and POSTs a real
  # JSON-RPC `tools/call` for `local_tracker_set_state` to it via `curl`. `--mcp-config` is always
  # the last flag in `ClaudeCode.AppServer`'s argv, followed only by file path(s) (a repo
  # `.mcp.json`, if any, then Symphony's own generated file last) — so the last argv element
  # observed after `--mcp-config` is always Symphony's own config, the one this fixture needs.
  defp write_fake_claude_mcp_tool_call!(path) do
    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"composition-fixture"}'

    MCP_CONFIG_PATH=""
    FOUND_FLAG=0
    for arg in "$@"; do
      if [ "$FOUND_FLAG" = "1" ]; then
        MCP_CONFIG_PATH="$arg"
      fi
      if [ "$arg" = "--mcp-config" ]; then
        FOUND_FLAG=1
      fi
    done

    MCP_URL=$(sed -n 's/.*"url":"\\([^"]*\\)".*/\\1/p' "$MCP_CONFIG_PATH")

    curl -s -o /dev/null -X POST "$MCP_URL" \\
      -H 'Content-Type: application/json' \\
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"local_tracker_set_state","arguments":{"state":"in_progress"}}}'

    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    """)

    File.chmod!(path, 0o755)
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
