defmodule SymphonyElixir.CodingAgentTest do
  use SymphonyElixir.TestSupport

  test "Codex.AppServer satisfies the fixed-session CodingAgent contract across multiple turns" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-coding-agent-fixed-session-#{System.unique_integer([:positive])}"
      )

    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "coding-agent-fixed-session.trace")
    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

    on_exit(fn ->
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODINGAGENT")
      File.mkdir_p!(workspace)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      # One long-lived fake app-server process serves both turns over the same
      # port: initialize -> initialized (no reply) -> thread/start (once) ->
      # turn/start + turn/completed, twice, reusing the fixed thread id.
      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/coding-agent-fixed-session.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-coding-agent-fixed"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-coding-agent-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-coding-agent-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-coding-agent-fixed-session",
        identifier: "MT-CODINGAGENT",
        title: "Fixed session across turns",
        description: "Prove CodingAgent's fixed-session contract directly against Codex.AppServer",
        state: "In Progress",
        url: "https://example.org/issues/MT-CODINGAGENT",
        labels: ["backend"]
      }

      assert {:ok, session} = AppServer.start_session(workspace, [])

      assert {:ok, _turn_result_1} = AppServer.run_turn(session, "first turn", issue, [])
      assert {:ok, _turn_result_2} = AppServer.run_turn(session, "second turn", issue, [])

      trace = File.read!(trace_file)

      json_lines =
        trace
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(fn line ->
          line
          |> String.trim_leading("JSON:")
          |> Jason.decode!()
        end)

      thread_start_count = Enum.count(json_lines, &(&1["method"] == "thread/start"))
      turn_start_count = Enum.count(json_lines, &(&1["method"] == "turn/start"))

      assert thread_start_count == 1
      assert turn_start_count == 2

      assert :ok = AppServer.stop_session(session)
      assert :ok = AppServer.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end
end
