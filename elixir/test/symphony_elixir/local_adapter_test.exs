defmodule SymphonyElixir.Local.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Local.Adapter, as: LocalAdapter
  alias SymphonyElixir.Local.AgentTool, as: LocalAgentTool
  alias SymphonyElixir.Local.{Init, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-local-adapter-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    data_path = Path.join(dir, "local_tracker.json")

    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, data_path: data_path}
  end

  describe "validate_config/1 (startup/config-validation coverage)" do
    test "both files absent surfaces local_tracker_not_initialized", %{data_path: data_path} do
      assert {:error, :local_tracker_not_initialized} = LocalAdapter.validate_config(tracker_settings(data_path))
    end

    test "data present without a marker surfaces local_tracker_ambiguous_state", %{data_path: data_path} do
      seed_issues(data_path, %{})

      assert {:error, {:local_tracker_ambiguous_state, :marker_missing}} =
               LocalAdapter.validate_config(tracker_settings(data_path))
    end

    test "established-then-lost data surfaces local_tracker_corrupt", %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)
      File.rm!(data_path)

      assert {:error, {:local_tracker_corrupt, :missing_after_established}} =
               LocalAdapter.validate_config(tracker_settings(data_path))
    end

    test "established-but-unparseable data surfaces local_tracker_corrupt", %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)
      File.write!(data_path, "{not json")

      assert {:error, {:local_tracker_corrupt, {:invalid_json, _message}}} =
               LocalAdapter.validate_config(tracker_settings(data_path))
    end

    test "a valid established store validates normally", %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)
      assert :ok = LocalAdapter.validate_config(tracker_settings(data_path))
    end

    test "a blank or missing provider path is rejected without touching the filesystem", %{data_path: data_path} do
      refute File.exists?(data_path)

      assert {:error, :invalid_local_tracker_path} =
               LocalAdapter.validate_config(tracker_settings(data_path, %{"path" => ""}))

      assert {:error, :invalid_local_tracker_path} =
               LocalAdapter.validate_config(tracker_settings(data_path, %{"path" => nil}))

      refute File.exists?(data_path)
    end
  end

  describe "normal operation" do
    test "reads normalize records 1:1, filter by state, dispatchable is always true, no secrets", %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)

      seed_issues(data_path, %{
        "1" => %{
          "identifier" => "LOC-1",
          "title" => "First",
          "description" => "desc",
          "priority" => 2,
          "state" => "todo",
          "branch_name" => "loc-1",
          "url" => "file:///1",
          "assignee_id" => "alice",
          "labels" => ["bug", "core"],
          "blocked_by" => [],
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        },
        "2" => %{"state" => "done"}
      })

      start_singleton!(data_path)

      assert {:ok, [issue]} = LocalAdapter.fetch_issues_by_states(["todo"])
      assert issue.id == "1"
      assert issue.native_ref == nil
      assert issue.identifier == "LOC-1"
      assert issue.title == "First"
      assert issue.description == "desc"
      assert issue.priority == 2
      assert issue.state == "todo"
      assert issue.branch_name == "loc-1"
      assert issue.url == "file:///1"
      assert issue.assignee_id == "alice"
      assert issue.labels == ["bug", "core"]
      assert issue.blocked_by == []
      assert issue.dispatchable == true
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at

      assert {:ok, [%{id: "2", dispatchable: true, state: "done"}]} = LocalAdapter.fetch_issues_by_states(["done"])
      assert {:ok, []} = LocalAdapter.fetch_issues_by_states(["in_progress"])

      assert {:ok, by_id} = LocalAdapter.fetch_issues_by_ids(["2", "missing"])
      assert [%{id: "2"}] = by_id

      assert LocalAdapter.secret_environment_names(tracker_settings(data_path)) == []
      assert [%{"name" => "local_tracker_set_state"}] = LocalAdapter.agent_tool_specs()
    end

    test "a record missing optional fields still maps cleanly with safe defaults", %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)
      seed_issues(data_path, %{"1" => %{"state" => "todo"}})
      start_singleton!(data_path)

      assert {:ok, [issue]} = LocalAdapter.fetch_issues_by_ids(["1"])
      assert issue.id == "1"
      assert issue.identifier == "1"
      assert issue.labels == []
      assert issue.blocked_by == []
      assert issue.dispatchable == true
      assert issue.created_at == nil
      assert issue.updated_at == nil
    end

    test "a malformed timestamp or missing state degrades to safe defaults instead of crashing", %{
      data_path: data_path
    } do
      assert {:ok, :initialized} = Init.run(data_path)

      seed_issues(data_path, %{
        "1" => %{"created_at" => "not-a-timestamp"},
        "2" => %{"state" => "todo"}
      })

      start_singleton!(data_path)

      assert {:ok, [issue]} = LocalAdapter.fetch_issues_by_ids(["1"])
      assert issue.state == nil
      assert issue.created_at == nil

      assert {:ok, [%{id: "2"}]} = LocalAdapter.fetch_issues_by_states(["todo"])
      refute Enum.any?(elem(LocalAdapter.fetch_issues_by_states(["todo"]), 1), &(&1.id == "1"))
    end

    test "a non-map issue record surfaces as a structured tracker error instead of raising", %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)
      seed_issues(data_path, %{"1" => "todo", "2" => %{"state" => "todo"}})
      start_singleton!(data_path)

      assert {:error, {:local_tracker_corrupt, {:invalid_shape, {:non_map_issue_record, "1", "todo"}}}} =
               LocalAdapter.fetch_issues_by_states(["todo"])

      assert {:error, {:local_tracker_corrupt, {:invalid_shape, {:non_map_issue_record, "1", "todo"}}}} =
               LocalAdapter.fetch_issues_by_ids(["2"])
    end
  end

  describe "local_tracker_set_state (session-scoped mutation)" do
    test "mutates only the bound issue, is idempotent on same-value, and leaves other records untouched", %{
      data_path: data_path
    } do
      assert {:ok, :initialized} = Init.run(data_path)
      seed_issues(data_path, %{"1" => %{"state" => "todo"}, "2" => %{"state" => "todo"}})
      start_singleton!(data_path)

      bound_issue = %Issue{id: "1", state: "todo"}

      response =
        LocalAdapter.execute_agent_tool("local_tracker_set_state", %{"state" => "in_progress"}, issue: bound_issue)

      assert response["success"] == true

      assert {:ok, [%{id: "1", state: "in_progress"}]} = LocalAdapter.fetch_issues_by_ids(["1"])
      assert {:ok, [%{id: "2", state: "todo"}]} = LocalAdapter.fetch_issues_by_ids(["2"])

      before = File.read!(data_path)

      idempotent =
        LocalAdapter.execute_agent_tool("local_tracker_set_state", %{"state" => "in_progress"}, issue: bound_issue)

      assert idempotent["success"] == true
      assert File.read!(data_path) == before

      cannot_target_unbound_record =
        LocalAdapter.execute_agent_tool("local_tracker_set_state", %{"state" => "done"}, issue: %Issue{id: "does-not-exist"})

      assert cannot_target_unbound_record["success"] == false
      assert {:ok, [%{id: "2", state: "todo"}]} = LocalAdapter.fetch_issues_by_ids(["2"])
    end

    test "reports a structured failure when there is no bound issue in context" do
      response = LocalAgentTool.execute("local_tracker_set_state", %{"state" => "done"}, [])
      assert response["success"] == false
      assert %{"error" => %{"message" => message}} = Jason.decode!(response["output"])
      assert is_binary(message)
    end

    test "rejects malformed arguments without calling the store" do
      response = LocalAgentTool.execute("local_tracker_set_state", %{}, issue: %Issue{id: "1"})
      assert response["success"] == false

      response = LocalAgentTool.execute("local_tracker_set_state", %{"state" => ""}, issue: %Issue{id: "1"})
      assert response["success"] == false
    end

    test "reports unsupported tools" do
      response = LocalAgentTool.execute("not_local_tracker", %{}, [])
      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["supportedTools"] == ["local_tracker_set_state"]
    end

    test "a write against a store whose directory vanished after start degrades to a structured error, not a crash", %{
      dir: dir,
      data_path: data_path
    } do
      assert {:ok, :initialized} = Init.run(data_path)
      seed_issues(data_path, %{"1" => %{"state" => "todo"}})
      start_singleton!(data_path)

      File.rm_rf!(dir)

      response =
        LocalAdapter.execute_agent_tool("local_tracker_set_state", %{"state" => "in_progress"}, issue: %Issue{id: "1"})

      assert response["success"] == false
      assert %{"error" => %{"message" => message}} = Jason.decode!(response["output"])
      assert is_binary(message)
    end
  end

  describe "production wiring" do
    test "a WorkflowStore restart starts the Local.Store singleton and Tracker binds local_tracker_set_state", %{
      data_path: data_path
    } do
      assert {:ok, :initialized} = Init.run(data_path)
      seed_issues(data_path, %{"1" => %{"state" => "todo"}})

      write_local_workflow!(Workflow.workflow_file_path(), data_path)
      restart_workflow_store!()

      assert Config.structural_settings!().tracker_kind == "local"
      assert Config.structural_settings!().tracker_provider_path == data_path
      assert Tracker.adapter() == LocalAdapter

      binding = Tracker.bind_agent_tools()
      assert binding.adapter == LocalAdapter
      assert binding.secret_environment_names == []
      assert [%{"name" => "local_tracker_set_state"}] = binding.tool_specs

      assert {:ok, [%{id: "1", state: "todo"}]} = LocalAdapter.fetch_issues_by_ids(["1"])
      assert :ok = Config.validate!()
    end

    test "a stale already-registered Local.Store does not crash a WorkflowStore restart", %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)
      seed_issues(data_path, %{"1" => %{"state" => "todo"}})

      start_singleton!(data_path)

      write_local_workflow!(Workflow.workflow_file_path(), data_path)
      restart_workflow_store!()

      assert Config.structural_settings!().tracker_provider_path == data_path
      assert {:ok, [%{id: "1"}]} = LocalAdapter.fetch_issues_by_ids(["1"])
    end
  end

  defp tracker_settings(data_path, provider_overrides \\ %{}) do
    %{
      kind: "local",
      provider: Map.merge(%{"path" => data_path}, provider_overrides),
      active_states: ["todo", "in_progress", "blocked"],
      terminal_states: ["done", "cancelled"]
    }
  end

  defp seed_issues(data_path, issues) do
    File.write!(data_path, Jason.encode!(%{"format_version" => 1, "issues" => issues}))
  end

  defp start_singleton!(data_path) do
    {:ok, pid} = Store.start_link(path: data_path, name: SymphonyElixir.Local.Store)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp write_local_workflow!(path, data_path) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: local
        provider:
          path: #{Jason.encode!(data_path)}
      ---

      Resolve the assigned work item.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
