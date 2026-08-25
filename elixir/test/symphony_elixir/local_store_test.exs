defmodule SymphonyElixir.LocalStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Local.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-local-store-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    data_path = Path.join(dir, "local_tracker.json")
    marker_path = Store.marker_path(data_path)

    on_exit(fn ->
      File.chmod(dir, 0o755)
      File.rm_rf!(dir)
    end)

    %{dir: dir, data_path: data_path, marker_path: marker_path}
  end

  defp start_store!(data_path) do
    {:ok, pid} = Store.start_link(path: data_path)
    pid
  end

  defp write_data!(data_path, content) when is_binary(content) do
    File.write!(data_path, content)
  end

  defp write_valid_data!(data_path, issues \\ %{}) do
    write_data!(data_path, Jason.encode!(%{"format_version" => 1, "issues" => issues}))
  end

  defp write_marker!(marker_path) do
    File.write!(marker_path, Jason.encode!(%{"established_at" => "2026-01-01T00:00:00Z"}))
  end

  describe "read/1 decision table (research.md R2)" do
    test "both files absent is reported as not yet initialized, and nothing is written", %{data_path: data_path, marker_path: marker_path} do
      store = start_store!(data_path)

      assert {:error, :local_tracker_not_initialized} = Store.read(store)
      refute File.exists?(data_path)
      refute File.exists?(marker_path)
    end

    test "data present without a marker is ambiguous, never auto-resolved, and left untouched", %{data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path, %{"1" => %{"state" => "todo"}})
      store = start_store!(data_path)

      assert {:error, {:local_tracker_ambiguous_state, :marker_missing}} = Store.read(store)
      assert {:error, {:local_tracker_ambiguous_state, :marker_missing}} = Store.read(store)
      refute File.exists?(marker_path)
      assert File.read!(data_path) == Jason.encode!(%{"format_version" => 1, "issues" => %{"1" => %{"state" => "todo"}}})
    end

    test "unparseable data present without a marker is still ambiguous, not corrupt", %{data_path: data_path} do
      write_data!(data_path, "not json")
      store = start_store!(data_path)

      assert {:error, {:local_tracker_ambiguous_state, :marker_missing}} = Store.read(store)
    end

    test "marker present with the data file missing is FR-013 established-state loss", %{data_path: data_path, marker_path: marker_path} do
      write_marker!(marker_path)
      store = start_store!(data_path)

      assert {:error, {:local_tracker_corrupt, :missing_after_established}} = Store.read(store)
      refute File.exists?(data_path)
    end

    test "marker present with unparseable JSON data is corrupt, never silently reset", %{data_path: data_path, marker_path: marker_path} do
      write_marker!(marker_path)
      write_data!(data_path, "{not json")
      store = start_store!(data_path)

      original = File.read!(data_path)
      assert {:error, {:local_tracker_corrupt, {:invalid_json, _message}}} = Store.read(store)
      assert File.read!(data_path) == original
    end

    test "marker present with a wrong-shape data file is corrupt", %{data_path: data_path, marker_path: marker_path} do
      write_marker!(marker_path)
      write_data!(data_path, Jason.encode!(%{"format_version" => 2, "issues" => %{}}))
      store = start_store!(data_path)

      assert {:error, {:local_tracker_corrupt, {:invalid_shape, _decoded}}} = Store.read(store)
    end

    test "marker present but unreadable (a directory, not a file) is treated as established-state loss", %{data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path)
      File.mkdir_p!(marker_path)
      store = start_store!(data_path)

      assert {:error, {:local_tracker_corrupt, {:marker_unreadable, _reason}}} = Store.read(store)
    end

    test "marker present with valid data is normal operation", %{data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path, %{"1" => %{"state" => "todo"}})
      write_marker!(marker_path)
      store = start_store!(data_path)

      assert {:ok, %{format_version: 1, issues: %{"1" => %{"state" => "todo"}}}} = Store.read(store)
    end

    test "data path being a directory (not a regular file) is reported ambiguous via the same unreadable branch", %{data_path: data_path, marker_path: marker_path} do
      File.mkdir_p!(data_path)
      refute File.exists?(marker_path)
      store = start_store!(data_path)

      assert {:error, {:local_tracker_ambiguous_state, :marker_missing}} = Store.read(store)
    end

    test "out-of-band changes are observed on the next call, never cached", %{data_path: data_path, marker_path: marker_path} do
      store = start_store!(data_path)
      assert {:error, :local_tracker_not_initialized} = Store.read(store)

      write_valid_data!(data_path)
      write_marker!(marker_path)

      assert {:ok, %{issues: %{}}} = Store.read(store)

      File.rm!(data_path)
      assert {:error, {:local_tracker_corrupt, :missing_after_established}} = Store.read(store)
    end
  end

  describe "set_issue_state/3 (the one ongoing lifecycle write)" do
    test "rewrites the target issue's state and updated_at, atomically replacing the data file", %{data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path, %{"1" => %{"id" => "1", "state" => "todo", "updated_at" => nil}})
      write_marker!(marker_path)
      store = start_store!(data_path)

      assert {:ok, %{"state" => "in_progress", "updated_at" => updated_at}} = Store.set_issue_state(store, "1", "in_progress")
      assert is_binary(updated_at)

      assert {:ok, %{issues: %{"1" => %{"state" => "in_progress"}}}} = Store.read(store)
    end

    test "is an idempotent no-op success when the new state matches the current value", %{data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path, %{"1" => %{"id" => "1", "state" => "todo", "updated_at" => "2026-01-01T00:00:00Z"}})
      write_marker!(marker_path)
      store = start_store!(data_path)

      before = File.read!(data_path)
      assert {:ok, %{"state" => "todo", "updated_at" => "2026-01-01T00:00:00Z"}} = Store.set_issue_state(store, "1", "todo")
      assert File.read!(data_path) == before
    end

    test "returns :issue_not_found for an unknown id and writes nothing", %{data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path)
      write_marker!(marker_path)
      store = start_store!(data_path)

      before = File.read!(data_path)
      assert {:error, :issue_not_found} = Store.set_issue_state(store, "missing", "done")
      assert File.read!(data_path) == before
    end

    test "on a not-yet-established store, returns the same read error and creates nothing", %{data_path: data_path, marker_path: marker_path} do
      store = start_store!(data_path)

      assert {:error, :local_tracker_not_initialized} = Store.set_issue_state(store, "1", "done")
      refute File.exists?(data_path)
      refute File.exists?(marker_path)
    end

    test "on an ambiguous store (data without marker), returns the ambiguous error and never writes the marker", %{data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path, %{"1" => %{"id" => "1", "state" => "todo"}})
      store = start_store!(data_path)

      assert {:error, {:local_tracker_ambiguous_state, :marker_missing}} = Store.set_issue_state(store, "1", "done")
      refute File.exists?(marker_path)
      assert %{"state" => "todo"} = get_in(Jason.decode!(File.read!(data_path)), ["issues", "1"])
    end

    test "restart: a fresh Store process pointed at the same path observes the persisted write", %{data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path, %{"1" => %{"id" => "1", "state" => "todo"}})
      write_marker!(marker_path)

      store1 = start_store!(data_path)
      assert {:ok, _} = Store.set_issue_state(store1, "1", "in_progress")
      GenServer.stop(store1)

      store2 = start_store!(data_path)
      assert {:ok, %{issues: %{"1" => %{"state" => "in_progress"}}}} = Store.read(store2)
    end

    test "two concurrent writers targeting different issues do not lose either update", %{data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path, %{
        "1" => %{"id" => "1", "state" => "todo"},
        "2" => %{"id" => "2", "state" => "todo"}
      })

      write_marker!(marker_path)
      store = start_store!(data_path)

      [task1, task2] =
        [{"1", "in_progress"}, {"2", "blocked"}]
        |> Enum.map(fn {id, new_state} ->
          Task.async(fn -> Store.set_issue_state(store, id, new_state) end)
        end)

      assert {:ok, _} = Task.await(task1)
      assert {:ok, _} = Task.await(task2)

      assert {:ok, %{issues: %{"1" => %{"state" => "in_progress"}, "2" => %{"state" => "blocked"}}}} = Store.read(store)
    end

    test "a write failure (unwritable directory) leaves the existing file untouched", %{dir: dir, data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path, %{"1" => %{"id" => "1", "state" => "todo"}})
      write_marker!(marker_path)
      store = start_store!(data_path)

      before = File.read!(data_path)
      File.chmod!(dir, 0o500)

      assert {:error, _reason} = Store.set_issue_state(store, "1", "in_progress")

      File.chmod!(dir, 0o755)
      assert File.read!(data_path) == before
    end
  end

  describe "default server argument (the named singleton)" do
    test "read/0 and set_issue_state/2 default to SymphonyElixir.Local.Store when no server is given", %{data_path: data_path, marker_path: marker_path} do
      write_valid_data!(data_path, %{"1" => %{"id" => "1", "state" => "todo"}})
      write_marker!(marker_path)

      {:ok, pid} = Store.start_link(path: data_path, name: SymphonyElixir.Local.Store)

      assert {:ok, %{issues: %{"1" => %{"state" => "todo"}}}} = Store.read()
      assert {:ok, %{"state" => "in_progress"}} = Store.set_issue_state("1", "in_progress")

      GenServer.stop(pid)
    end
  end
end
