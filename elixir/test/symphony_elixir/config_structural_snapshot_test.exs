defmodule SymphonyElixir.ConfigStructuralSnapshotTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter, as: LinearAdapter
  alias SymphonyElixir.Local.Adapter, as: LocalAdapter
  alias SymphonyElixir.Local.Init, as: LocalInit
  alias SymphonyElixir.Tracker.Memory

  test "a live tracker.kind edit does not take effect until the WorkflowStore restarts" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    restart_workflow_store!()

    assert Config.structural_settings!().tracker_kind == "linear"
    assert Tracker.adapter() == LinearAdapter
    assert Tracker.bind_agent_tools().secret_environment_names == ["LINEAR_API_KEY"]

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert Config.structural_settings!().tracker_kind == "linear"
    assert Tracker.adapter() == LinearAdapter

    assert Tracker.bind_agent_tools().secret_environment_names == ["LINEAR_API_KEY"],
           "the pinned Linear adapter must keep requiring LINEAR_API_KEY until an actual restart, " <>
             "even though the live-reloaded tracker.kind already reads \"memory\""

    restart_workflow_store!()

    assert Config.structural_settings!().tracker_kind == "memory"
    assert Tracker.adapter() == Memory
    assert Tracker.bind_agent_tools().secret_environment_names == []
  end

  test "a live agent_execution.kind edit does not take effect until the WorkflowStore restarts" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_execution_kind: "codex")
    restart_workflow_store!()

    assert Config.structural_settings!().agent_execution_kind == "codex"

    write_workflow_file!(Workflow.workflow_file_path(), agent_execution_kind: "claude_code")

    assert Config.settings!().agent_execution.kind == "claude_code"

    assert Config.structural_settings!().agent_execution_kind == "codex",
           "agent_execution.kind must stay pinned to the original structural selection until an " <>
             "actual restart, even though the live-reloaded value already reads \"claude_code\""

    restart_workflow_store!()

    assert Config.structural_settings!().agent_execution_kind == "claude_code"
  end

  test "a non-tracker.kind dynamic field still reloads live without a restart" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "before-token",
      codex_turn_timeout_ms: 111_000
    )

    restart_workflow_store!()

    assert Config.settings!().tracker.api_key == "before-token"
    assert Config.settings!().codex.turn_timeout_ms == 111_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "after-token",
      codex_turn_timeout_ms: 222_000
    )

    assert Config.settings!().tracker.api_key == "after-token"
    assert Config.settings!().codex.turn_timeout_ms == 222_000
    assert Config.structural_settings!().tracker_kind == "linear"
  end

  test "structural_settings! falls back to a direct load when WorkflowStore is not running" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert Config.structural_settings!().tracker_kind == "linear"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.structural_settings!().tracker_kind == "memory"

    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "structural_settings! raises when WorkflowStore is not running and the workflow file is missing" do
    existing_path = Workflow.workflow_file_path()
    missing_path = Path.join(Path.dirname(existing_path), "MISSING_STRUCTURAL_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Workflow.set_workflow_file_path(missing_path)

    assert_raise ArgumentError, fn -> Config.structural_settings!() end

    Workflow.set_workflow_file_path(existing_path)
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  describe "tracker.provider.path restart-only pinning under tracker.kind: local (research.md R9a)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "symphony-structural-local-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      store_a = Path.join(dir, "store_a.db")
      store_b = Path.join(dir, "store_b.db")

      assert {:ok, :initialized} = LocalInit.run(store_a)
      seed_local_tracker_issues!(store_a, %{"a" => %{"state" => "todo"}})

      assert {:ok, :initialized} = LocalInit.run(store_b)
      seed_local_tracker_issues!(store_b, %{"b" => %{"state" => "todo"}})

      %{store_a: store_a, store_b: store_b}
    end

    test "a live tracker.provider.path edit does not redirect reads until the WorkflowStore restarts", %{
      store_a: store_a,
      store_b: store_b
    } do
      write_local_workflow!(Workflow.workflow_file_path(), store_a)
      restart_workflow_store!()

      assert Config.structural_settings!().tracker_kind == "local"
      assert Config.structural_settings!().tracker_provider_path == store_a
      assert Tracker.adapter() == LocalAdapter
      assert {:ok, [%{id: "a"}]} = Tracker.fetch_issues_by_ids(["a"])

      write_local_workflow!(Workflow.workflow_file_path(), store_b)

      assert Config.settings!().tracker.provider["path"] == store_b

      assert Config.structural_settings!().tracker_provider_path == store_a,
             "tracker.provider.path must stay pinned to the original resolved path until an actual restart"

      assert {:ok, [%{id: "a"}]} = Tracker.fetch_issues_by_ids(["a"]),
             "the pinned store must still be readable after a live path edit, not the new one"

      assert {:ok, []} = Tracker.fetch_issues_by_ids(["b"]),
             "the new path's data must not become visible mid-flight, before an actual restart"

      restart_workflow_store!()

      assert Config.structural_settings!().tracker_provider_path == store_b
      assert Tracker.adapter() == LocalAdapter
      assert {:ok, [%{id: "b"}]} = Tracker.fetch_issues_by_ids(["b"])
      assert {:ok, []} = Tracker.fetch_issues_by_ids(["a"])
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
end
