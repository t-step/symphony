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

  Also covers T033 (quickstart.md Scenario 2 step 7; research.md R6a's per-run isolation): two
  concurrent `claude_code`-backed runs, driven by real `AgentRunner.run/3` dispatches against two
  distinct `tracker.kind: local` issues sharing the same on-disk store, each with its own
  fake-`claude` fixture instance scripted (not LLM-instructed) to call `local_tracker_set_state`
  against its own bound issue only. Overlap is forced with an explicit barrier/marker-file
  handshake (not a blind sleep): each fixture leaks its run's real generated MCP URL to a shared
  directory and then blocks on a `go` marker the test only writes once both runs' endpoints are
  observed live, so the test's own cross-token HTTP checks are guaranteed to run while both
  listeners are actually up. This mirrors `claude_code_mcp_server_test.exs`'s unit-level
  "cross-run isolation" describe block, but exercises it at full composition scope through the
  real `AgentRunner.run/3` -> `ClaudeCode.AppServer` -> `MCPServer` -> `Local.Store` path instead
  of constructing `MCPServer` instances directly.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Local.Init, as: LocalInit

  @issue_id "composition-1"
  @issue_id_a "composition-concurrent-a"
  @issue_id_b "composition-concurrent-b"

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

  test "two concurrent claude_code-backed local-tracker runs remain isolated across MCP bindings",
       %{test_root: test_root, data_path: data_path, workspace_root: workspace_root, fake_claude: fake_claude} do
    barrier_dir = Path.join(test_root, "barrier")
    File.mkdir_p!(barrier_dir)

    write_fake_claude_concurrent_isolation!(fake_claude, barrier_dir)

    assert {:ok, :initialized} = LocalInit.run(data_path)
    seed_two_dispatchable_issues!(data_path, @issue_id_a, @issue_id_b)

    write_local_claude_workflow!(Workflow.workflow_file_path(), data_path, workspace_root, fake_claude,
      max_concurrent_agents: 2,
      turn_timeout_ms: 20_000
    )

    restart_workflow_store!()

    assert {:ok, [%Issue{state: "todo"} = issue_a]} = Tracker.fetch_issues_by_ids([@issue_id_a])
    assert {:ok, [%Issue{state: "todo"} = issue_b]} = Tracker.fetch_issues_by_ids([@issue_id_b])

    test_pid = self()

    task_a = Task.async(fn -> AgentRunner.run(issue_a, test_pid, max_turns: 1) end)
    task_b = Task.async(fn -> AgentRunner.run(issue_b, test_pid, max_turns: 1) end)

    leak_a = Path.join(barrier_dir, "#{@issue_id_a}.leak")
    leak_b = Path.join(barrier_dir, "#{@issue_id_b}.leak")

    # Explicit barrier handshake (not a sleep-and-hope): block until BOTH fixtures have leaked
    # their run's real generated MCP endpoint, so both listeners are provably alive and
    # concurrently in flight before the cross-token checks below run against them.
    {url_a, url_b} = await_both_leaked!(leak_a, leak_b)

    {port_a, token_a} = parse_mcp_url(url_a)
    {port_b, token_b} = parse_mcp_url(url_b)

    refute port_a == port_b, "expected each concurrent run to bind a distinct MCP listener port"
    refute token_a == token_b, "expected each concurrent run to mint a distinct per-run MCP bearer token"

    # Composition-scope mirror of claude_code_mcp_server_test.exs's unit-level "cross-run
    # isolation" check (T021): run A's token against run B's live port, and vice versa, is
    # rejected -- proven against the real endpoints this dispatch generated, while both runs are
    # still overlapping in flight.
    assert cross_token_request(port_b, token_a).status == 401,
           "run A's token must be rejected by run B's live MCP listener"

    assert cross_token_request(port_a, token_b).status == 401,
           "run B's token must be rejected by run A's live MCP listener"

    # Release both fixtures to perform their own scripted mutation and complete the turn.
    File.write!(Path.join(barrier_dir, "go"), "go")

    assert :ok = Task.await(task_a, 20_000)
    assert :ok = Task.await(task_b, 20_000)

    lifecycle_events_a = drain_lifecycle_events(@issue_id_a)
    lifecycle_events_b = drain_lifecycle_events(@issue_id_b)

    for {issue_id, lifecycle_events} <- [{@issue_id_a, lifecycle_events_a}, {@issue_id_b, lifecycle_events_b}] do
      assert Enum.any?(lifecycle_events, &(&1.event == :turn_completed)),
             "expected #{issue_id}'s run to reach a terminal turn_completed lifecycle event, got: #{inspect(lifecycle_events)}"
    end

    on_disk_issues =
      data_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("issues")

    record_a = Map.fetch!(on_disk_issues, @issue_id_a)
    record_b = Map.fetch!(on_disk_issues, @issue_id_b)

    # Each issue received only its own run's mutation -- no cross-binding occurred.
    assert record_a["state"] == "in_progress-#{@issue_id_a}"
    assert record_a["identifier"] == @issue_id_a

    assert record_b["state"] == "in_progress-#{@issue_id_b}"
    assert record_b["identifier"] == @issue_id_b
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

  defp write_local_claude_workflow!(path, data_path, workspace_root, fake_claude, opts \\ []) do
    max_concurrent_agents = Keyword.get(opts, :max_concurrent_agents, 1)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, 10_000)

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
        max_concurrent_agents: #{max_concurrent_agents}
        max_turns: 1
      agent_execution:
        kind: claude_code
      claude_code:
        command: #{Jason.encode!(fake_claude)}
        read_timeout_ms: 5000
        turn_timeout_ms: #{turn_timeout_ms}
      observability:
        dashboard_enabled: false
      ---
      Resolve the assigned work item.
      """
    )
  end

  defp seed_two_dispatchable_issues!(data_path, id_a, id_b) do
    File.write!(
      data_path,
      Jason.encode!(%{
        "format_version" => 1,
        "issues" => %{
          id_a => %{"state" => "todo", "identifier" => id_a, "title" => "Concurrent isolation A"},
          id_b => %{"state" => "todo", "identifier" => id_b, "title" => "Concurrent isolation B"}
        }
      })
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

  # Drives the same real MCP-client role as `write_fake_claude_mcp_tool_call!/1` (locates its own
  # `--mcp-config` argv value, extracts the real ephemeral `symphony_tracker` URL), but is shared
  # by BOTH concurrent runs in the isolation test -- `claude_code.command` is one process-wide
  # config value, so both runs launch the identical fixture file. Each invocation tells itself
  # apart from the other using `$PWD`'s basename: `Workspace.workspace_key/1` returns the issue
  # identifier verbatim for these ASCII-safe test ids, so each run's working directory is already
  # named after its own bound issue -- no custom env var is available to thread through, since
  # `ClaudeCode.AppServer.claude_subprocess_env/0` strips every environment variable off the
  # allow-list before the subprocess launches. Before performing its own scripted mutation, each
  # invocation leaks its real generated MCP URL to `barrier_dir/<run_key>.leak` and then blocks
  # (bounded, not indefinitely) on a `barrier_dir/go` marker -- the explicit handshake the test
  # uses to guarantee both listeners are observed live and overlapping before either mutates.
  defp write_fake_claude_concurrent_isolation!(path, barrier_dir) do
    File.write!(path, """
    #!/bin/sh
    RUN_KEY=$(basename "$PWD")

    printf '{"type":"system","subtype":"init","session_id":"composition-fixture-%s"}\\n' "$RUN_KEY"

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

    printf '%s' "$MCP_URL" > "#{barrier_dir}/$RUN_KEY.leak"

    GO_FILE="#{barrier_dir}/go"
    i=0
    while [ ! -f "$GO_FILE" ] && [ "$i" -lt 150 ]; do
      i=$((i + 1))
      sleep 0.05
    done

    curl -s -o /dev/null -X POST "$MCP_URL" \\
      -H 'Content-Type: application/json' \\
      -d "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":1,\\"method\\":\\"tools/call\\",\\"params\\":{\\"name\\":\\"local_tracker_set_state\\",\\"arguments\\":{\\"state\\":\\"in_progress-$RUN_KEY\\"}}}"

    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    """)

    File.chmod!(path, 0o755)
  end

  # Bounded poll (not an indefinite/blind sleep) for both fixtures' barrier leak files to appear.
  # This is the test side of the leak-file/`go`-marker handshake documented on
  # `write_fake_claude_concurrent_isolation!/2`.
  defp await_both_leaked!(leak_a, leak_b, attempts \\ 150)

  defp await_both_leaked!(_leak_a, _leak_b, 0) do
    flunk("timed out waiting for both fake-claude fixtures to leak their MCP endpoint")
  end

  defp await_both_leaked!(leak_a, leak_b, attempts) do
    if File.exists?(leak_a) and File.exists?(leak_b) do
      {File.read!(leak_a) |> String.trim(), File.read!(leak_b) |> String.trim()}
    else
      Process.sleep(20)
      await_both_leaked!(leak_a, leak_b, attempts - 1)
    end
  end

  defp parse_mcp_url(url) do
    uri = URI.parse(url)
    token = String.trim_leading(uri.path, "/mcp/")
    {uri.port, token}
  end

  defp cross_token_request(port, token) do
    Req.post!("http://127.0.0.1:#{port}/mcp/#{token}",
      json: %{"jsonrpc" => "2.0", "id" => 99, "method" => "tools/list"}
    )
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
