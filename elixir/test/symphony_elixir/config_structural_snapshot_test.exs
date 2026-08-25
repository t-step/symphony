defmodule SymphonyElixir.ConfigStructuralSnapshotTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter, as: LinearAdapter
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
end
