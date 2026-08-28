defmodule SymphonyElixir.Bindle.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Bindle.Adapter, as: BindleAdapter
  alias SymphonyElixir.Bindle.Owner

  defmodule FakeCli do
    def claim(repo_path, bindle_bin, id, owner) do
      send(self(), {:bindle_claim_called, repo_path, bindle_bin, id, owner})
      Process.get(:fake_cli_claim_result, {:ok, "claimed"})
    end

    def release(repo_path, bindle_bin, id, owner) do
      send(self(), {:bindle_release_called, repo_path, bindle_bin, id, owner})
      Process.get(:fake_cli_release_result, {:ok, "released"})
    end

    def done(repo_path, bindle_bin, id) do
      send(self(), {:bindle_done_called, repo_path, bindle_bin, id})
      {:ok, "done"}
    end

    def publish(repo_path, bindle_bin) do
      send(self(), {:bindle_publish_called, repo_path, bindle_bin})
      {:ok, "published"}
    end
  end

  setup do
    repo_root =
      Path.join(System.tmp_dir!(), "bindle-adapter-repo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(repo_root, ".bindle-work"))
    projection_path = Path.join(repo_root, ".bindle-work/symphony-projection.sqlite3")

    on_exit(fn -> File.rm_rf(repo_root) end)

    {:ok, repo_root: repo_root, projection_path: projection_path}
  end

  test "resolve_repo_path/1 defaults to Config.workflow_dir(), resolve_projection_path/1 defaults relative to repo_path",
       %{repo_root: repo_root} do
    assert BindleAdapter.resolve_repo_path(%{}) == Config.workflow_dir()

    assert BindleAdapter.resolve_projection_path(%{}) ==
             Path.join(Config.workflow_dir(), ".bindle-work/symphony-projection.sqlite3")

    assert BindleAdapter.resolve_repo_path(%{"repo_path" => repo_root}) == repo_root

    assert BindleAdapter.resolve_projection_path(%{"repo_path" => repo_root}) ==
             Path.join(repo_root, ".bindle-work/symphony-projection.sqlite3")

    # An explicit projection path override is resolved relative to repo_path, never independently
    # relative to workflow_dir() — so the read side and the CLI's write side (cd: repo_path) cannot
    # silently diverge.
    assert BindleAdapter.resolve_projection_path(%{"repo_path" => repo_root, "path" => "custom.sqlite3"}) ==
             Path.join(repo_root, "custom.sqlite3")
  end

  test "resolve_bindle_bin/1 and resolve_owner_id_path/1 apply their documented defaults" do
    assert BindleAdapter.resolve_bindle_bin(%{}) == "bindle"
    assert BindleAdapter.resolve_bindle_bin(%{"bindle_bin" => "/opt/bindle/bin/bindle"}) == "/opt/bindle/bin/bindle"

    assert BindleAdapter.resolve_owner_id_path(%{}) ==
             Path.join(Config.workflow_dir(), ".symphony/bindle_owner_id")

    assert BindleAdapter.resolve_owner_id_path(%{"owner_id_path" => "custom_owner_id"}) ==
             Path.expand("custom_owner_id", Config.workflow_dir())
  end

  test "fetch_issues_by_states/1 and fetch_issues_by_ids/1 return correctly-mapped issues through the configured tracker.kind: bindle deployment",
       %{repo_root: repo_root, projection_path: projection_path} do
    build_projection!(projection_path, [
      %{
        id: "task-1",
        identifier: "T-1",
        title: "Do the thing",
        description: "desc",
        status: "open",
        dispatchable: 1,
        created_at: "2026-01-01T00:00:00Z"
      }
    ])

    write_bindle_workflow!(repo_root)

    assert {:ok, [issue]} = BindleAdapter.fetch_issues_by_states(["open"])
    assert issue.id == "task-1"
    assert issue.state == "open"
    assert issue.dispatchable == true

    assert {:ok, [issue]} = BindleAdapter.fetch_issues_by_ids(["task-1"])
    assert issue.identifier == "T-1"

    assert {:ok, []} = BindleAdapter.fetch_issues_by_ids(["does-not-exist"])
  end

  test "validate_config/1 fails loud on a missing/incompatible/unreadable projection and succeeds against a real one",
       %{repo_root: repo_root, projection_path: projection_path} do
    settings = %{provider: %{"repo_path" => repo_root}}

    assert {:error, _reason} = BindleAdapter.validate_config(settings)

    build_projection!(projection_path, [])
    assert :ok = BindleAdapter.validate_config(settings)
  end

  test "secret_environment_names/1 declares none" do
    assert BindleAdapter.secret_environment_names(%{}) == []
  end

  test "agent_tool_specs/0 exposes exactly one tool, scoped to the session's bound task; acquire_issue/2 and release_issue/2 never call done/publish (FR-019/FR-023, Acceptance Scenario 1, SC-005)",
       %{repo_root: repo_root, projection_path: projection_path} do
    build_projection!(projection_path, [])
    write_bindle_workflow!(repo_root)
    Application.put_env(:symphony_elixir, :bindle_cli_module, FakeCli)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :bindle_cli_module) end)

    assert [%{"name" => "bindle_mark_task_done"}] = BindleAdapter.agent_tool_specs()

    issue = %Issue{id: "task-1", identifier: "T-1", title: "Do it"}
    # Exercise both the default-`opts` (arity-1) and explicit-`opts` (arity-2) call shapes.
    assert :ok = BindleAdapter.acquire_issue(issue)
    assert :ok = BindleAdapter.acquire_issue(issue, [])
    assert :ok = BindleAdapter.release_issue("task-1")
    assert :ok = BindleAdapter.release_issue("task-1", [])

    refute_received {:bindle_done_called, _, _, _}
    refute_received {:bindle_publish_called, _, _}

    # execute_agent_tool/3 delegates to AgentTool.execute/3 — reached only through this adapter-level
    # entry point in production (via Tracker.execute_bound_agent_tool/4), so it needs its own direct
    # exercise here, not only AgentTool's own unit tests.
    result = BindleAdapter.execute_agent_tool("bindle_mark_task_done", %{}, issue: issue)
    assert result["success"] == true
    assert_received {:bindle_done_called, ^repo_root, "bindle", "task-1"}
  end

  test "acquire_issue/2 calls Cli.claim/4 with the resolved repo_path/bindle_bin/owner and propagates its result",
       %{repo_root: repo_root, projection_path: projection_path} do
    owner_id_path = Path.join(repo_root, "owner_id")
    build_projection!(projection_path, [])
    write_bindle_workflow!(repo_root, owner_id_path: owner_id_path)
    Application.put_env(:symphony_elixir, :bindle_cli_module, FakeCli)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :bindle_cli_module) end)

    issue = %Issue{id: "task-1", identifier: "T-1", title: "Do it"}

    Process.put(:fake_cli_claim_result, {:ok, "claimed"})
    assert :ok = BindleAdapter.acquire_issue(issue, [])
    assert_received {:bindle_claim_called, ^repo_root, "bindle", "task-1", owner}
    assert is_binary(owner) and owner != ""

    Process.put(:fake_cli_claim_result, {:error, {:bindle_cli_failed, 1, "already_claimed"}})
    assert {:error, {:bindle_cli_failed, 1, "already_claimed"}} = BindleAdapter.acquire_issue(issue, [])
  end

  test "release_issue/2 takes only the issue id, calls Cli.release/4 with the same owner identity, and propagates its result",
       %{repo_root: repo_root, projection_path: projection_path} do
    owner_id_path = Path.join(repo_root, "owner_id")
    build_projection!(projection_path, [])
    write_bindle_workflow!(repo_root, owner_id_path: owner_id_path)
    Application.put_env(:symphony_elixir, :bindle_cli_module, FakeCli)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :bindle_cli_module) end)

    assert {:ok, owner} = Owner.id(owner_id_path)

    Process.put(:fake_cli_release_result, {:ok, "released"})
    assert :ok = BindleAdapter.release_issue("task-1", [])
    assert_received {:bindle_release_called, ^repo_root, "bindle", "task-1", ^owner}

    Process.put(:fake_cli_release_result, {:error, {:bindle_cli_unavailable, "enoent"}})
    assert {:error, {:bindle_cli_unavailable, "enoent"}} = BindleAdapter.release_issue("task-1", [])
  end

  test "tracker binds tracker.kind: bindle and resolves the configured adapter", %{
    repo_root: repo_root,
    projection_path: projection_path
  } do
    build_projection!(projection_path, [])
    write_bindle_workflow!(repo_root)

    assert {:ok, SymphonyElixir.Bindle.Adapter} = Tracker.adapter_for_kind("bindle")
    assert :ok = Config.validate!()
  end

  defp write_bindle_workflow!(repo_root, opts \\ []) do
    owner_id_line =
      case Keyword.get(opts, :owner_id_path) do
        nil -> ""
        path -> "\n    owner_id_path: #{Jason.encode!(path)}"
      end

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: bindle
        provider:
          repo_path: #{Jason.encode!(repo_root)}#{owner_id_line}
        active_states: ["open"]
        terminal_states: ["done", "superseded"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    restart_workflow_store!()
  end

  defp build_projection!(path, rows, opts \\ []) do
    schema_version = Keyword.get(opts, :schema_version, 1)

    {:ok, conn} = Exqlite.Sqlite3.open(path)

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

    Enum.each(rows, fn row ->
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          conn,
          "INSERT INTO task_projection (id, identifier, title, description, status, dispatchable, created_at) VALUES (?,?,?,?,?,?,?)"
        )

      :ok =
        Exqlite.Sqlite3.bind(stmt, [
          row.id,
          row.identifier,
          row.title,
          row.description,
          row.status,
          row.dispatchable,
          row.created_at
        ])

      :done = Exqlite.Sqlite3.step(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)
    end)

    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA user_version = #{schema_version}")
    :ok = Exqlite.Sqlite3.close(conn)
  end
end
