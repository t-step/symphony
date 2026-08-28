defmodule SymphonyElixir.Bindle.AgentToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Bindle.AgentTool

  defmodule FakeCli do
    def done(repo_path, bindle_bin, id) do
      send(self(), {:bindle_done_called, repo_path, bindle_bin, id})
      Process.get(:fake_cli_done_result, {:ok, "done"})
    end

    def publish(repo_path, bindle_bin) do
      send(self(), {:bindle_publish_called, repo_path, bindle_bin})
      Process.get(:fake_cli_publish_result, {:ok, "published"})
    end
  end

  setup do
    repo_root = Path.join(System.tmp_dir!(), "bindle-agent-tool-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo_root, ".bindle-work"))

    {:ok, conn} = Exqlite.Sqlite3.open(Path.join(repo_root, ".bindle-work/symphony-projection.sqlite3"))

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE task_projection (
        id TEXT PRIMARY KEY NOT NULL,
        identifier TEXT NOT NULL,
        title TEXT,
        description TEXT,
        status TEXT NOT NULL,
        dispatchable INTEGER NOT NULL,
        created_at TEXT NOT NULL
      )
      """)

    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA user_version = 1")
    :ok = Exqlite.Sqlite3.close(conn)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: bindle
        provider:
          repo_path: #{Jason.encode!(repo_root)}
        active_states: ["open"]
        terminal_states: ["done"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    restart_workflow_store!()
    Application.put_env(:symphony_elixir, :bindle_cli_module, FakeCli)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :bindle_cli_module) end)

    {:ok, repo_root: repo_root}
  end

  test "tool_specs/0 declares exactly one tool with no task-id parameter in its inputSchema" do
    assert [%{"name" => "bindle_mark_task_done", "inputSchema" => schema}] = AgentTool.tool_specs()
    refute Map.has_key?(schema["properties"] || %{}, "id")
    refute Map.has_key?(schema["properties"] || %{}, "task_id")
    refute Map.has_key?(schema["properties"] || %{}, "issue_id")
  end

  test "resolves the target exclusively from opts[:issue], ignoring any model-supplied argument", %{
    repo_root: repo_root
  } do
    issue = %Issue{id: "task-bound", identifier: "T-BOUND", title: "Bound task"}

    result =
      AgentTool.execute(
        "bindle_mark_task_done",
        %{"id" => "task-attacker-supplied", "task_id" => "also-ignored"},
        issue: issue
      )

    assert result["success"] == true
    assert_received {:bindle_done_called, ^repo_root, "bindle", "task-bound"}
    refute_received {:bindle_done_called, _, _, "task-attacker-supplied"}
  end

  test "calls done/3 then, on success, publish/2 — success payload reflects both", %{repo_root: repo_root} do
    issue = %Issue{id: "task-1", identifier: "T-1", title: "Do it"}

    result = AgentTool.execute("bindle_mark_task_done", %{}, issue: issue)

    assert_received {:bindle_done_called, ^repo_root, "bindle", "task-1"}
    assert_received {:bindle_publish_called, ^repo_root, "bindle"}

    assert result["success"] == true
    payload = Jason.decode!(result["output"])
    assert payload["id"] == "task-1"
    assert payload["publish"] == "ok"
  end

  test "a done failure is returned distinguishably and never attempts publish", %{repo_root: _repo_root} do
    Process.put(:fake_cli_done_result, {:error, {:bindle_cli_failed, 1, "not_open"}})

    issue = %Issue{id: "task-2", identifier: "T-2", title: "Already done"}
    result = AgentTool.execute("bindle_mark_task_done", %{}, issue: issue)

    assert result["success"] == false
    assert Jason.decode!(result["output"])["error"]["reason"] =~ "not_open"
    refute_received {:bindle_publish_called, _, _}
  end

  test "a publish failure after a successful done is surfaced as a distinct field, never retries done", %{
    repo_root: repo_root
  } do
    Process.put(:fake_cli_publish_result, {:error, {:bindle_cli_unavailable, "enoent"}})

    issue = %Issue{id: "task-3", identifier: "T-3", title: "Publish fails"}
    result = AgentTool.execute("bindle_mark_task_done", %{}, issue: issue)

    # done succeeded overall (this feature's own success), publish failure is distinct.
    assert result["success"] == true
    payload = Jason.decode!(result["output"])
    assert payload["publish"] == "failed"
    assert payload["publish_error"] =~ "bindle_cli_unavailable"

    # done/3 was called exactly once — never retried because publish failed.
    assert_received {:bindle_done_called, ^repo_root, "bindle", "task-3"}
    refute_received {:bindle_done_called, ^repo_root, "bindle", "task-3"}
  end

  test "no bound issue in opts is a distinguishable failure that never calls the CLI" do
    result = AgentTool.execute("bindle_mark_task_done", %{}, [])

    assert result["success"] == false
    assert Jason.decode!(result["output"])["error"]["message"] =~ "No bound issue"
    refute_received {:bindle_done_called, _, _, _}
  end

  test "an unsupported tool name reports the one supported tool" do
    result = AgentTool.execute("not_bindle_mark_task_done", %{}, issue: %Issue{id: "x"})

    assert result["success"] == false
    assert Jason.decode!(result["output"])["error"]["supportedTools"] == ["bindle_mark_task_done"]
  end
end
