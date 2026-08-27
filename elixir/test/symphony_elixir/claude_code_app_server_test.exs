defmodule SymphonyElixir.ClaudeCode.AppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.{AppServer, MCPServer}
  alias SymphonyElixir.Local.{Adapter, Init}
  alias SymphonyElixir.Tracker

  setup do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-claude-app-server-test-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-1")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    on_exit(fn -> File.rm_rf(test_root) end)

    %{test_root: test_root, workspace_root: workspace_root, workspace: workspace, issue: build_issue()}
  end

  describe "start_session/2 remote-worker rejection" do
    test "rejects a non-nil worker_host before any other validation", %{workspace: workspace} do
      assert {:error, :remote_worker_not_supported} =
               AppServer.start_session(workspace, worker_host: "worker.example.org")
    end
  end

  describe "start_session/2 issue requirement" do
    test "fails without raising when no issue is given", %{workspace: workspace} do
      assert {:error, :issue_required} = AppServer.start_session(workspace, [])
    end
  end

  describe "start_session/2 workspace boundary validation" do
    test "rejects the workspace root itself", %{test_root: test_root, issue: issue} do
      workspace_root = Path.join(test_root, "wb-root-workspaces")
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.start_session(workspace_root, issue: issue)
    end

    test "rejects a path outside the configured workspace root", %{test_root: test_root, issue: issue} do
      workspace_root = Path.join(test_root, "wb-outside-workspaces")
      outside_workspace = Path.join(test_root, "wb-outside")
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.start_session(outside_workspace, issue: issue)
    end

    test "rejects a symlink escape out of the configured workspace root", %{test_root: test_root, issue: issue} do
      workspace_root = Path.join(test_root, "wb-symlink-workspaces")
      outside_workspace = Path.join(test_root, "wb-symlink-outside")
      symlink_workspace = Path.join(workspace_root, "MT-2000")
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.start_session(symlink_workspace, issue: issue)
    end
  end

  describe "start_session/2 partial-start cleanup" do
    test "an MCP listener bind failure surfaces as an error, not a crash", %{workspace: workspace, issue: issue} do
      {:ok, occupier} = MCPServer.start_link(tracker_binding: Tracker.bind_agent_tools(), issue: issue)

      try do
        assert {:error, _reason} =
                 AppServer.start_session(workspace, issue: issue, mcp_start_opts: [port: occupier.port])
      after
        MCPServer.stop(occupier)
      end
    end

    test "a --mcp-config write failure stops the just-started MCP listener instead of leaking it", %{
      workspace: workspace,
      issue: issue,
      test_root: test_root
    } do
      {:ok, probe} = MCPServer.start_link(tracker_binding: Tracker.bind_agent_tools(), issue: issue)
      free_port = probe.port
      assert :ok = MCPServer.stop(probe)

      unwritable_dir = Path.join(test_root, "unwritable-mcp-config-dir")
      File.mkdir_p!(unwritable_dir)
      File.chmod!(unwritable_dir, 0o000)
      on_exit(fn -> File.chmod(unwritable_dir, 0o755) end)

      assert {:error, {:mcp_config_write_failed, _reason}} =
               AppServer.start_session(workspace,
                 issue: issue,
                 mcp_config_dir: unwritable_dir,
                 mcp_start_opts: [port: free_port]
               )

      # Proves AppServer's own cleanup (`MCPServer.stop/1` on the config-write failure branch)
      # actually ran: the port is free again, so a fresh listener can rebind it. A leaked
      # listener from AppServer's failed attempt would still hold the port, and this rebind
      # would fail instead.
      assert {:ok, verifier} =
               MCPServer.start_link(tracker_binding: Tracker.bind_agent_tools(), issue: issue, port: free_port)

      MCPServer.stop(verifier)
    end
  end

  describe "start_session/2 MCP wiring" do
    test "starts one MCP listener, writes a --mcp-config file pointing at it, and exposes the bound tracker's tools",
         %{workspace: workspace, issue: issue, test_root: test_root} do
      data_path = Path.join(test_root, "local_tracker.db")
      assert {:ok, :initialized} = Init.run(data_path)
      seed_local_tracker_issues!(data_path, %{"1" => %{"state" => "todo"}})

      write_local_workflow!(Workflow.workflow_file_path(), data_path, Path.dirname(workspace))
      restart_workflow_store!()

      assert {:ok, session} = AppServer.start_session(workspace, issue: %{issue | id: "1"})

      try do
        assert Process.alive?(session.mcp_server.pid)
        assert File.exists?(session.mcp_config_path)

        config = session.mcp_config_path |> File.read!() |> Jason.decode!()
        url = config["mcpServers"]["symphony_tracker"]["url"]
        assert url == "http://127.0.0.1:#{session.mcp_server.port}/mcp/#{session.mcp_server.token}"
        assert config["mcpServers"]["symphony_tracker"]["type"] == "http"

        list_response = Req.post!(url, json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
        assert [%{"name" => "local_tracker_set_state"}] = list_response.body["result"]["tools"]

        call_response =
          Req.post!(url,
            json: %{
              "jsonrpc" => "2.0",
              "id" => 2,
              "method" => "tools/call",
              "params" => %{"name" => "local_tracker_set_state", "arguments" => %{"state" => "in_progress"}}
            }
          )

        refute call_response.body["result"]["isError"]

        {:ok, [%{id: "1", state: "in_progress"}]} = Adapter.fetch_issues_by_ids(["1"])
      after
        AppServer.stop_session(session)
      end
    end
  end

  describe "run_turn/4 session lifecycle" do
    test "turn 1 launches with --session-id; later turns launch with --resume the same session id", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :two_turn_success)

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:ok, %{session_id: session_id} = turn1} = AppServer.run_turn(session, "do the thing", issue, [])
        assert session_id == session.session_id

        first_argv = File.read!(Path.join(workspace, "argv-first.txt"))
        assert first_argv =~ "--session-id"
        assert first_argv =~ session_id

        assert {:ok, %{session_id: ^session_id}} = AppServer.run_turn(session, "continue", issue, [])

        resume_argv = File.read!(Path.join(workspace, "argv-resume.txt"))
        assert resume_argv =~ "--resume"
        assert resume_argv =~ session_id
        refute resume_argv =~ "--session-id"

        assert turn1.result == "pong"
        assert Process.alive?(session.mcp_server.pid)
      after
        AppServer.stop_session(session)
      end
    end

    test "a fresh session never resumes another session's Claude session id", %{
      workspace_root: workspace_root,
      issue: issue
    } do
      workspace_a = Path.join(workspace_root, "MT-A")
      workspace_b = Path.join(workspace_root, "MT-B")
      File.mkdir_p!(workspace_a)
      File.mkdir_p!(workspace_b)
      write_fake_claude!(workspace_a, :two_turn_success)
      write_fake_claude!(workspace_b, :two_turn_success)

      assert {:ok, session_a} = AppServer.start_session(workspace_a, issue: issue)
      assert {:ok, session_b} = AppServer.start_session(workspace_b, issue: issue)

      try do
        assert session_a.session_id != session_b.session_id

        assert {:ok, %{session_id: sid_a}} = AppServer.run_turn(session_a, "a", issue, [])
        assert {:ok, %{session_id: sid_b}} = AppServer.run_turn(session_b, "b", issue, [])

        assert sid_a == session_a.session_id
        assert sid_b == session_b.session_id
        assert File.read!(Path.join(workspace_a, "argv-first.txt")) =~ sid_a
        assert File.read!(Path.join(workspace_b, "argv-first.txt")) =~ sid_b
      after
        AppServer.stop_session(session_a)
        AppServer.stop_session(session_b)
      end
    end
  end

  describe "run_turn/4 first-turn/resume revert semantics" do
    test "a process crash before system/init leaves the session first-turn so retry still uses --session-id", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :crash_before_init_once_then_success)

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:error, {:port_exit, 1}} = AppServer.run_turn(session, "prompt", issue, [])

        crashed_argv = File.read!(Path.join(workspace, "argv-crashed.txt"))
        assert crashed_argv =~ "--session-id"

        assert {:ok, %{session_id: session_id}} = AppServer.run_turn(session, "retry", issue, [])
        assert session_id == session.session_id

        retry_argv = File.read!(Path.join(workspace, "argv-after-crash.txt"))
        assert retry_argv =~ "--session-id"
        refute retry_argv =~ "--resume"
      after
        AppServer.stop_session(session)
      end
    end

    test "a timeout before system/init leaves the session first-turn so retry still uses --session-id", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :silent, claude_code_read_timeout_ms: 100, claude_code_turn_timeout_ms: 5_000)

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:error, :turn_timeout} = AppServer.run_turn(session, "prompt", issue, [])

        # Switch to a fixture that actually completes for the retry — the first attempt's tight
        # read_timeout_ms already did its job forcing a failure before `system/init`; the retry
        # only needs to prove which CLI flag it launches with, not race a subprocess against
        # another tight timeout.
        write_fake_claude!(workspace, :two_turn_success,
          claude_code_read_timeout_ms: 5_000,
          claude_code_turn_timeout_ms: 5_000
        )

        assert {:ok, %{session_id: session_id}} = AppServer.run_turn(session, "retry", issue, [])
        assert session_id == session.session_id

        retry_argv = File.read!(Path.join(workspace, "argv-first.txt"))
        assert retry_argv =~ "--session-id"
        refute retry_argv =~ "--resume"
      after
        AppServer.stop_session(session)
      end
    end

    test "an executable-not-found launch failure leaves the session first-turn so retry still uses --session-id",
         %{workspace: workspace, issue: issue} do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(workspace),
        claude_code_command: "/nonexistent/symphony-claude-binary-#{System.unique_integer([:positive])}"
      )

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:error, {:claude_executable_not_found, _name}} =
                 AppServer.run_turn(session, "prompt", issue, [])

        write_fake_claude!(workspace, :two_turn_success)

        assert {:ok, %{session_id: session_id}} = AppServer.run_turn(session, "retry", issue, [])
        assert session_id == session.session_id

        retry_argv = File.read!(Path.join(workspace, "argv-first.txt"))
        assert retry_argv =~ "--session-id"
      after
        AppServer.stop_session(session)
      end
    end

    test "a turn that fails after system/init does not revert an already-established session", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :crash_mid_turn)

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:error, {:port_exit, 1}} = AppServer.run_turn(session, "prompt", issue, [])

        write_fake_claude!(workspace, :two_turn_success)

        assert {:ok, %{session_id: session_id}} = AppServer.run_turn(session, "retry", issue, [])
        assert session_id == session.session_id

        resume_argv = File.read!(Path.join(workspace, "argv-resume.txt"))
        assert resume_argv =~ "--resume"
        assert resume_argv =~ session_id
        refute resume_argv =~ "--session-id"
      after
        AppServer.stop_session(session)
      end
    end
  end

  describe "run_turn/4 claude_code.command parsing contract" do
    test "claude_code.command tokenizes as plain whitespace-separated argv, appending extra flags verbatim", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :two_turn_success)
      base_command = SymphonyElixir.Config.settings!().claude_code.command

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(workspace),
        claude_code_command: base_command <> " --extra-test-flag"
      )

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:ok, _turn} = AppServer.run_turn(session, "prompt", issue, [])

        first_argv = File.read!(Path.join(workspace, "argv-first.txt"))
        assert first_argv =~ "--extra-test-flag"
      after
        AppServer.stop_session(session)
      end
    end

    test "claude_code.command does not interpret shell quoting — quotes end up as literal argv characters", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :two_turn_success)
      base_command = SymphonyElixir.Config.settings!().claude_code.command

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(workspace),
        claude_code_command: base_command <> ~s( --append-system-prompt "hello world")
      )

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:ok, _turn} = AppServer.run_turn(session, "prompt", issue, [])

        first_argv = File.read!(Path.join(workspace, "argv-first.txt"))
        # A real shell would deliver one `hello world` argument; the naive whitespace split
        # here instead delivers two literal, quote-scarred tokens — this is the documented,
        # intentional contract (see `resolve_command/0`'s moduledoc comment), not a bug.
        assert first_argv =~ "\"hello"
        assert first_argv =~ "world\""
      after
        AppServer.stop_session(session)
      end
    end
  end

  describe "run_turn/4 repository MCP composition" do
    test "when <workspace>/.mcp.json exists, it is passed before Symphony's generated config under one --mcp-config",
         %{workspace: workspace, issue: issue} do
      write_fake_claude!(workspace, :two_turn_success)

      File.write!(
        Path.join(workspace, ".mcp.json"),
        Jason.encode!(%{"mcpServers" => %{"repo_server" => %{"command" => "noop"}}})
      )

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:ok, _turn} = AppServer.run_turn(session, "prompt", issue, [])

        argv = argv_lines(workspace, "argv-first.txt")
        # Compared against `session.workspace` (already canonicalized by `validate_workspace_cwd/1`),
        # not the raw `workspace` test fixture path, since the two can differ in spelling (e.g.
        # macOS's `/var` -> `/private/var` symlink) while naming the same on-disk file.
        expected_repo_path = Path.join(session.workspace, ".mcp.json")

        assert Enum.count(argv, &(&1 == "--mcp-config")) == 1
        # Repo config first, Symphony's own generated config last — see the dedicated
        # same-name-collision regression test below for why this order matters.
        assert mcp_config_flag_values(argv) == [expected_repo_path, session.mcp_config_path]
      after
        AppServer.stop_session(session)
      end
    end

    test "Symphony's generated config is always the LAST --mcp-config entry, so a repo .mcp.json " <>
           "declaring its own \"symphony_tracker\" server can no longer shadow Symphony's real one",
         %{workspace: workspace, issue: issue} do
      write_fake_claude!(workspace, :two_turn_success)

      File.write!(
        Path.join(workspace, ".mcp.json"),
        Jason.encode!(%{"mcpServers" => %{"symphony_tracker" => %{"command" => "attacker-controlled"}}})
      )

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:ok, _turn} = AppServer.run_turn(session, "prompt", issue, [])

        argv = argv_lines(workspace, "argv-first.txt")

        # This test asserts only the half of the invariant Symphony controls: composition order.
        # The Claude CLI's own last-config-wins same-name-collision behavior was independently
        # verified against the installed CLI (research.md R8 Correction Addendum) and is not
        # re-proven here — a live `claude` invocation has no place in this unit suite.
        assert List.last(mcp_config_flag_values(argv)) == session.mcp_config_path
      after
        AppServer.stop_session(session)
      end
    end

    test "when <workspace>/.mcp.json does not exist, only Symphony's generated config is passed", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :two_turn_success)
      refute File.exists?(Path.join(workspace, ".mcp.json"))

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:ok, _turn} = AppServer.run_turn(session, "prompt", issue, [])

        argv = argv_lines(workspace, "argv-first.txt")

        assert Enum.count(argv, &(&1 == "--mcp-config")) == 1
        assert mcp_config_flag_values(argv) == [session.mcp_config_path]
      after
        AppServer.stop_session(session)
      end
    end

    test "a <workspace>/.mcp.json that is actually a directory is treated as absent, not passed as a config file",
         %{workspace: workspace, issue: issue} do
      write_fake_claude!(workspace, :two_turn_success)
      File.mkdir_p!(Path.join(workspace, ".mcp.json"))

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:ok, _turn} = AppServer.run_turn(session, "prompt", issue, [])

        argv = argv_lines(workspace, "argv-first.txt")

        assert mcp_config_flag_values(argv) == [session.mcp_config_path]
      after
        AppServer.stop_session(session)
      end
    end

    test "an operator-supplied claude_code.command with its own --mcp-config is not deduplicated — Symphony's own is still appended after it",
         %{workspace: workspace, issue: issue} do
      write_fake_claude!(workspace, :two_turn_success)
      base_command = SymphonyElixir.Config.settings!().claude_code.command

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(workspace),
        claude_code_command: base_command <> " --mcp-config /tmp/operator-supplied.json"
      )

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:ok, _turn} = AppServer.run_turn(session, "prompt", issue, [])

        argv = argv_lines(workspace, "argv-first.txt")

        # The operator's own --mcp-config/value survive verbatim (base_args are never rewritten
        # or deduplicated) and Symphony's own --mcp-config invocation is still appended after —
        # unchanged from the pre-existing append-only contract; this composition change only
        # affects how many files follow Symphony's *own* --mcp-config invocation.
        assert Enum.count(argv, &(&1 == "--mcp-config")) == 2
        assert "/tmp/operator-supplied.json" in argv
        assert List.last(argv) == session.mcp_config_path
      after
        AppServer.stop_session(session)
      end
    end
  end

  describe "run_turn/4 environment isolation" do
    test "excludes OPENAI_API_KEY and passes only ANTHROPIC_API_KEY through", %{workspace: workspace, issue: issue} do
      write_fake_claude!(workspace, :env_dump)
      System.put_env("OPENAI_API_KEY", "sk-openai-should-not-leak")
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-allowed")
      System.put_env("SYMPHONY_TEST_UNRELATED_VAR", "should-not-leak-either")

      on_exit(fn ->
        System.delete_env("OPENAI_API_KEY")
        System.delete_env("ANTHROPIC_API_KEY")
        System.delete_env("SYMPHONY_TEST_UNRELATED_VAR")
      end)

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:ok, _} = AppServer.run_turn(session, "dump env", issue, [])

        env_dump = File.read!(Path.join(workspace, "env-first.txt"))
        refute env_dump =~ "OPENAI_API_KEY"
        refute env_dump =~ "SYMPHONY_TEST_UNRELATED_VAR"
        assert env_dump =~ "ANTHROPIC_API_KEY=sk-ant-allowed"
      after
        AppServer.stop_session(session)
      end
    end
  end

  describe "run_turn/4 process-launch failure" do
    test "a missing configured claude executable surfaces as an error, not a crash", %{
      workspace: workspace,
      issue: issue
    } do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(workspace),
        claude_code_command: "/nonexistent/symphony-claude-binary-#{System.unique_integer([:positive])}"
      )

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        events = capture_events()

        assert {:error, {:claude_executable_not_found, _name}} =
                 AppServer.run_turn(session, "prompt", issue, on_message: events.on_message)

        assert Enum.any?(events.get.(), &(&1.event == :startup_failed))
      after
        AppServer.stop_session(session)
      end
    end
  end

  describe "run_turn/4 stream-json outcomes" do
    test "tolerates unknown/non-JSON stream lines and still resolves the terminal result", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :noisy_success)

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        events = capture_events()

        assert {:ok, %{result: "ok"}} =
                 AppServer.run_turn(session, "prompt", issue, on_message: events.on_message)

        assert Enum.any?(events.get.(), &(&1.event == :session_started))
        assert Enum.any?(events.get.(), &(&1.event == :turn_completed))
      after
        AppServer.stop_session(session)
      end
    end

    test "a failure-path result (is_error: true) is a synthetic fixture, not observed from the real CLI", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :failure_result)

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        events = capture_events()

        assert {:error, {:turn_failed, %{"is_error" => true}}} =
                 AppServer.run_turn(session, "prompt", issue, on_message: events.on_message)

        assert Enum.any?(events.get.(), &(&1.event == :turn_failed))
      after
        AppServer.stop_session(session)
      end
    end

    test "a malformed terminal result (missing is_error) is a controlled error, not a crash", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :malformed_result)

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:error, {:malformed_result, %{"type" => "result"}}} =
                 AppServer.run_turn(session, "prompt", issue, [])
      after
        AppServer.stop_session(session)
      end
    end

    test "an unexpected subprocess exit before the terminal result is a controlled error", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :crash_mid_turn)

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:error, {:port_exit, 1}} = AppServer.run_turn(session, "prompt", issue, [])
      after
        AppServer.stop_session(session)
      end
    end
  end

  describe "run_turn/4 timeouts" do
    test "a silent bootstrap phase (no system/init) times out on claude_code.read_timeout_ms", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :silent, claude_code_read_timeout_ms: 100, claude_code_turn_timeout_ms: 5_000)

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:error, :turn_timeout} = AppServer.run_turn(session, "prompt", issue, [])
      after
        AppServer.stop_session(session)
      end
    end

    test "a silent turn phase (init but no result) times out on claude_code.turn_timeout_ms", %{
      workspace: workspace,
      issue: issue
    } do
      write_fake_claude!(workspace, :init_then_silent,
        claude_code_read_timeout_ms: 5_000,
        claude_code_turn_timeout_ms: 100
      )

      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      try do
        assert {:error, :turn_timeout} = AppServer.run_turn(session, "prompt", issue, [])
      after
        AppServer.stop_session(session)
      end
    end
  end

  describe "stop_session/1 cleanup" do
    test "stops the MCP listener and removes the temp --mcp-config file", %{workspace: workspace, issue: issue} do
      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

      assert Process.alive?(session.mcp_server.pid)
      assert File.exists?(session.mcp_config_path)

      assert :ok = AppServer.stop_session(session)

      refute Process.alive?(session.mcp_server.pid)
      refute File.exists?(session.mcp_config_path)
    end

    test "tolerates being called when the listener is already stopped and the config file is already gone", %{
      workspace: workspace,
      issue: issue
    } do
      assert {:ok, session} = AppServer.start_session(workspace, issue: issue)
      assert :ok = AppServer.stop_session(session)

      assert :ok = AppServer.stop_session(session)
    end
  end

  defp build_issue(id \\ "issue-1") do
    %Issue{
      id: id,
      identifier: "MT-#{id}",
      title: "Test issue",
      description: "test",
      state: "in_progress",
      url: "https://example.org/issues/#{id}",
      labels: []
    }
  end

  # `write_fake_claude!/2`'s fixtures capture argv via `printf '%s\n' "$@"`, which — because
  # `"$@"` is quoted — prints exactly one argv element per line regardless of embedded
  # whitespace, so splitting on newlines recovers the original argv list element-for-element.
  defp argv_lines(workspace, filename) do
    workspace |> Path.join(filename) |> File.read!() |> String.split("\n", trim: true)
  end

  # `--mcp-config` takes one or more space-separated file arguments; this collects every
  # argv element following a `--mcp-config` occurrence up to (not including) the next flag.
  defp mcp_config_flag_values(argv) do
    argv
    |> Enum.with_index()
    |> Enum.filter(fn {token, _index} -> token == "--mcp-config" end)
    |> Enum.flat_map(fn {_token, index} ->
      argv |> Enum.drop(index + 1) |> Enum.take_while(&(not String.starts_with?(&1, "-")))
    end)
  end

  defp capture_events do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    %{
      on_message: fn message -> Agent.update(agent, &[message | &1]) end,
      get: fn -> Agent.get(agent, &Enum.reverse/1) end
    }
  end

  defp write_local_workflow!(path, data_path, workspace_root) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: local
        provider:
          path: #{Jason.encode!(data_path)}
      workspace:
        root: #{Jason.encode!(workspace_root)}
      ---

      Resolve the assigned work item.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end

  defp write_fake_claude!(workspace, kind, overrides \\ [])

  defp write_fake_claude!(workspace, :two_turn_success, overrides) do
    write_fake_claude_script!(workspace, overrides, """
    #!/bin/sh
    case "$*" in
      *--session-id*) MARKER=first ;;
      *) MARKER=resume ;;
    esac
    printf '%s\\n' "$@" > "./argv-$MARKER.txt"
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"observed"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"pong"}'
    """)
  end

  defp write_fake_claude!(workspace, :env_dump, overrides) do
    write_fake_claude_script!(workspace, overrides, """
    #!/bin/sh
    case "$*" in
      *--session-id*) MARKER=first ;;
      *) MARKER=resume ;;
    esac
    env > "./env-$MARKER.txt"
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"observed"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    """)
  end

  defp write_fake_claude!(workspace, :noisy_success, overrides) do
    write_fake_claude_script!(workspace, overrides, """
    #!/bin/sh
    printf '%s\\n' 'not json at all, should be tolerated'
    printf '%s\\n' '{"type":"system","subtype":"hook_started"}'
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"observed"}'
    printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta"}}'
    printf '%s\\n' '{"type":"assistant","message":{"role":"assistant"}}'
    printf '%s\\n' '{"type":"rate_limit_event"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    """)
  end

  defp write_fake_claude!(workspace, :failure_result, overrides) do
    write_fake_claude_script!(workspace, overrides, """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"observed"}'
    printf '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}'
    """)
  end

  defp write_fake_claude!(workspace, :malformed_result, overrides) do
    write_fake_claude_script!(workspace, overrides, """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"observed"}'
    printf '%s\\n' '{"type":"result","other":"field"}'
    """)
  end

  defp write_fake_claude!(workspace, :crash_mid_turn, overrides) do
    write_fake_claude_script!(workspace, overrides, """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"observed"}'
    exit 1
    """)
  end

  defp write_fake_claude!(workspace, :silent, overrides) do
    write_fake_claude_script!(workspace, overrides, """
    #!/bin/sh
    sleep 2
    """)
  end

  defp write_fake_claude!(workspace, :init_then_silent, overrides) do
    write_fake_claude_script!(workspace, overrides, """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"observed"}'
    sleep 2
    """)
  end

  defp write_fake_claude!(workspace, :crash_before_init_once_then_success, overrides) do
    # The marker is created with the `: > file` shell builtin (no external `touch` fork/exec)
    # so it is guaranteed to exist before this process can possibly be killed by a timeout —
    # the alternative (an external `touch` process) can race against a tight read_timeout_ms
    # kill under real process-scheduling latency.
    write_fake_claude_script!(workspace, overrides, """
    #!/bin/sh
    if [ -f ./crashed-once.marker ]; then
      printf '%s\\n' "$@" > "./argv-after-crash.txt"
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"observed"}'
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"pong"}'
    else
      : > ./crashed-once.marker
      printf '%s\\n' "$@" > "./argv-crashed.txt"
      exit 1
    fi
    """)
  end

  defp write_fake_claude_script!(workspace, overrides, contents) do
    fake_binary = Path.join(workspace, "fake-claude")
    File.write!(fake_binary, contents)
    File.chmod!(fake_binary, 0o755)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge([workspace_root: Path.dirname(workspace), claude_code_command: fake_binary], overrides)
    )
  end
end
