defmodule SymphonyElixir.CLILocalTrackerInitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  test "defaults to ./WORKFLOW.md when no path is given" do
    parent = self()

    deps =
      base_deps(%{
        load_workflow: fn path ->
          send(parent, {:load_workflow, path})
          local_workflow()
        end
      })

    assert {:done, message} = CLI.evaluate(["local-tracker", "init"], deps)
    assert message =~ "initialized"
    assert_received {:load_workflow, path}
    assert path == Path.expand("WORKFLOW.md")
  end

  test "accepts an explicit WORKFLOW.md path" do
    parent = self()

    deps =
      base_deps(%{
        load_workflow: fn path ->
          send(parent, {:load_workflow, path})
          local_workflow()
        end
      })

    assert {:done, _message} = CLI.evaluate(["local-tracker", "init", "custom/WORKFLOW.md"], deps)
    assert_received {:load_workflow, path}
    assert path == Path.expand("custom/WORKFLOW.md")
  end

  test "threads --reset into Local.Init and delegates with the resolved provider path" do
    parent = self()

    deps =
      base_deps(%{
        load_workflow: fn _path -> local_workflow(%{"path" => "custom_store.json"}) end,
        local_tracker_init: fn path, opts ->
          send(parent, {:local_tracker_init, path, opts})
          {:ok, :reset}
        end
      })

    assert {:done, message} = CLI.evaluate(["local-tracker", "init", "--reset", "WORKFLOW.md"], deps)
    assert message =~ "reset and reinitialized"

    expected_path = Path.expand("custom_store.json", Path.dirname(Path.expand("WORKFLOW.md")))

    assert_received {:local_tracker_init, ^expected_path, opts}
    assert Keyword.get(opts, :reset) == true
  end

  test "delegates reset: false when --reset is not given" do
    parent = self()

    deps =
      base_deps(%{
        local_tracker_init: fn path, opts ->
          send(parent, {:local_tracker_init, path, opts})
          {:ok, :initialized}
        end
      })

    assert {:done, _message} = CLI.evaluate(["local-tracker", "init"], deps)
    assert_received {:local_tracker_init, _path, opts}
    assert Keyword.get(opts, :reset) == false
  end

  test "rejects a non-local tracker.kind as a usage error, never delegating to Local.Init" do
    deps =
      base_deps(%{
        load_workflow: fn _path -> {:ok, %{config: %{"tracker" => %{"kind" => "github"}}, prompt: "", prompt_template: ""}} end,
        local_tracker_init: fn _path, _opts -> flunk("must not delegate for a non-local tracker.kind") end
      })

    assert {:error, message} = CLI.evaluate(["local-tracker", "init"], deps)
    assert message =~ "tracker.kind must be \"local\""
  end

  test "surfaces a missing WORKFLOW.md as an error" do
    deps =
      base_deps(%{
        load_workflow: fn path -> {:error, {:missing_workflow_file, path, :enoent}} end,
        local_tracker_init: fn _path, _opts -> flunk("must not delegate when the workflow file is missing") end
      })

    assert {:error, message} = CLI.evaluate(["local-tracker", "init"], deps)
    assert message =~ "Missing WORKFLOW.md"
  end

  test "surfaces Local.Init failures (already established) as an actionable error" do
    deps = base_deps(%{local_tracker_init: fn _path, _opts -> {:error, :already_established} end})

    assert {:error, message} = CLI.evaluate(["local-tracker", "init"], deps)
    assert message =~ "already established"
    assert message =~ "--reset"
  end

  test "rejects malformed local-tracker init argument shapes" do
    deps = base_deps()

    assert {:error, message} = CLI.evaluate(["local-tracker", "init", "--unknown-flag"], deps)
    assert message =~ "Usage: symphony local-tracker init"

    assert {:error, message} = CLI.evaluate(["local-tracker", "init", "a.md", "b.md"], deps)
    assert message =~ "Usage: symphony local-tracker init"
  end

  test "every existing (non-local-tracker) CLI invocation shape is unaffected" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok =
             CLI.evaluate(
               ["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "WORKFLOW.md"],
               deps
             )

    assert_received {:workflow_set, _path}
  end

  defp local_workflow(provider_overrides \\ %{}) do
    tracker = %{"kind" => "local"}
    tracker = if map_size(provider_overrides) > 0, do: Map.put(tracker, "provider", provider_overrides), else: tracker

    {:ok, %{config: %{"tracker" => tracker}, prompt: "", prompt_template: ""}}
  end

  defp base_deps(overrides \\ %{}) do
    Map.merge(
      %{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
        load_workflow: fn _path -> local_workflow() end,
        local_tracker_init: fn _path, _opts -> {:ok, :initialized} end
      },
      overrides
    )
  end
end
