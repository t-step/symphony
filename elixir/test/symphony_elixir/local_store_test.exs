defmodule SymphonyElixir.LocalStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Local.Init
  alias SymphonyElixir.Local.Store
  alias SymphonyElixir.TestSupport

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-local-store-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    data_path = Path.join(dir, "local_tracker.db")

    on_exit(fn ->
      File.chmod(dir, 0o755)
      File.chmod(data_path, 0o644)
      File.rm_rf!(dir)
    end)

    %{dir: dir, data_path: data_path}
  end

  defp start_store!(data_path) do
    {:ok, pid} = Store.start_link(path: data_path)
    pid
  end

  defp establish!(data_path, issues \\ %{}) do
    assert {:ok, :initialized} = Init.run(data_path)
    if map_size(issues) > 0, do: TestSupport.seed_local_tracker_issues!(data_path, issues)
    :ok
  end

  defp write_marker!(data_path) do
    File.write!(Store.marker_path(data_path), Jason.encode!(%{"established_at" => "2026-01-01T00:00:00Z"}))
  end

  describe "read/1" do
    test "both absent is reported as not yet initialized, and nothing is created", %{data_path: data_path} do
      store = start_store!(data_path)

      assert {:error, :local_tracker_not_initialized} = Store.read(store)
      refute File.exists?(data_path)
    end

    test "an established, empty store reads as no issues", %{data_path: data_path} do
      establish!(data_path)
      store = start_store!(data_path)

      assert {:ok, %{issues: %{}}} = Store.read(store)
    end

    test "an established store with seeded issues reads them back", %{data_path: data_path} do
      establish!(data_path, %{"1" => %{"state" => "todo"}})
      store = start_store!(data_path)

      assert {:ok, %{issues: %{"1" => %{"state" => "todo"}}}} = Store.read(store)
    end

    test "a file that is not a valid SQLite database is reported corrupt, never crashes", %{data_path: data_path} do
      File.write!(data_path, "not a sqlite database")
      store = start_store!(data_path)

      assert {:error, {:local_tracker_corrupt, _reason}} = Store.read(store)
    end

    test "a SQLite database missing the work_items table/schema is reported corrupt", %{data_path: data_path} do
      {:ok, conn} = Exqlite.Basic.open(data_path)
      {:ok, _rows, _cols} = Exqlite.Basic.exec(conn, "CREATE TABLE unrelated (id TEXT)") |> Exqlite.Basic.rows()
      :ok = Exqlite.Basic.close(conn)
      write_marker!(data_path)

      store = start_store!(data_path)

      assert {:error, {:local_tracker_corrupt, :missing_schema}} = Store.read(store)
    end

    test "a row with unparseable JSON in a labels/blocked_by column is reported corrupt, not silently accepted", %{
      data_path: data_path
    } do
      establish!(data_path, %{"1" => %{"state" => "todo"}})

      {:ok, conn} = Exqlite.Basic.open(data_path)
      {:ok, _rows, _cols} = Exqlite.Basic.exec(conn, "UPDATE work_items SET labels = ? WHERE id = ?", ["not json", "1"]) |> Exqlite.Basic.rows()
      :ok = Exqlite.Basic.close(conn)

      store = start_store!(data_path)

      assert {:error, {:local_tracker_corrupt, {:invalid_column_json, "1", "labels", _message}}} = Store.read(store)
    end

    test "a row whose labels/blocked_by column is valid JSON but not a list is reported corrupt", %{
      data_path: data_path
    } do
      establish!(data_path, %{"1" => %{"state" => "todo"}})

      {:ok, conn} = Exqlite.Basic.open(data_path)

      {:ok, _rows, _cols} =
        Exqlite.Basic.exec(conn, "UPDATE work_items SET blocked_by = ? WHERE id = ?", [Jason.encode!(%{"not" => "a list"}), "1"])
        |> Exqlite.Basic.rows()

      :ok = Exqlite.Basic.close(conn)

      store = start_store!(data_path)

      assert {:error, {:local_tracker_corrupt, {:invalid_column_shape, "1", "blocked_by", %{"not" => "a list"}}}} =
               Store.read(store)
    end

    test "data path being a directory (not a regular file) is reported corrupt", %{data_path: data_path} do
      File.mkdir_p!(data_path)
      store = start_store!(data_path)

      assert {:error, {:local_tracker_corrupt, _reason}} = Store.read(store)
    end

    test "out-of-band establishment is observed on the next call, never cached", %{data_path: data_path} do
      store = start_store!(data_path)
      assert {:error, :local_tracker_not_initialized} = Store.read(store)

      establish!(data_path)

      assert {:ok, %{issues: %{}}} = Store.read(store)
    end

    test "an out-of-band deletion of the database file (after establishment) is observed as FR-013 established-state loss, not a fresh empty store",
         %{data_path: data_path} do
      establish!(data_path)
      store = start_store!(data_path)
      assert {:ok, %{issues: %{}}} = Store.read(store)

      File.rm!(data_path)

      assert {:error, {:local_tracker_corrupt, :missing_after_established}} = Store.read(store)
    end
  end

  describe "set_issue_state/3 (the one ongoing lifecycle write)" do
    test "rewrites the target issue's state and updated_at", %{data_path: data_path} do
      establish!(data_path, %{"1" => %{"state" => "todo"}})
      store = start_store!(data_path)

      assert {:ok, %{"state" => "in_progress", "updated_at" => updated_at}} = Store.set_issue_state(store, "1", "in_progress")
      assert is_binary(updated_at)

      assert {:ok, %{issues: %{"1" => %{"state" => "in_progress"}}}} = Store.read(store)
    end

    test "is an idempotent no-op success when the new state matches the current value", %{data_path: data_path} do
      establish!(data_path, %{"1" => %{"state" => "todo", "updated_at" => "2026-01-01T00:00:00Z"}})
      store = start_store!(data_path)

      before = Store.read(store)
      assert {:ok, %{"state" => "todo", "updated_at" => "2026-01-01T00:00:00Z"}} = Store.set_issue_state(store, "1", "todo")
      assert Store.read(store) == before
    end

    test "returns :issue_not_found for an unknown id and writes nothing", %{data_path: data_path} do
      establish!(data_path)
      store = start_store!(data_path)

      assert {:error, :issue_not_found} = Store.set_issue_state(store, "missing", "done")
      assert {:ok, %{issues: %{}}} = Store.read(store)
    end

    test "on a not-yet-established store, returns the same read error and creates nothing", %{data_path: data_path} do
      store = start_store!(data_path)

      assert {:error, :local_tracker_not_initialized} = Store.set_issue_state(store, "1", "done")
      refute File.exists?(data_path)
    end

    test "on a row with an unparseable JSON column, returns the corruption error and writes nothing", %{
      data_path: data_path
    } do
      establish!(data_path, %{"1" => %{"state" => "todo"}})

      {:ok, conn} = Exqlite.Basic.open(data_path)
      {:ok, _rows, _cols} = Exqlite.Basic.exec(conn, "UPDATE work_items SET labels = ? WHERE id = ?", ["not json", "1"]) |> Exqlite.Basic.rows()
      :ok = Exqlite.Basic.close(conn)

      store = start_store!(data_path)

      assert {:error, {:local_tracker_corrupt, {:invalid_column_json, "1", "labels", _message}}} =
               Store.set_issue_state(store, "1", "in_progress")
    end

    test "restart: a fresh Store process pointed at the same path observes the persisted write", %{data_path: data_path} do
      establish!(data_path, %{"1" => %{"state" => "todo"}})

      store1 = start_store!(data_path)
      assert {:ok, _} = Store.set_issue_state(store1, "1", "in_progress")
      GenServer.stop(store1)

      store2 = start_store!(data_path)
      assert {:ok, %{issues: %{"1" => %{"state" => "in_progress"}}}} = Store.read(store2)
    end

    test "two concurrent writers targeting different issues do not lose either update", %{data_path: data_path} do
      establish!(data_path, %{
        "1" => %{"state" => "todo"},
        "2" => %{"state" => "todo"}
      })

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

    test "a write failure (unwritable directory) leaves the existing data untouched", %{dir: dir, data_path: data_path} do
      establish!(data_path, %{"1" => %{"state" => "todo"}})
      store = start_store!(data_path)

      before = Store.read(store)
      File.chmod!(dir, 0o500)

      assert {:error, _reason} = Store.set_issue_state(store, "1", "in_progress")

      File.chmod!(dir, 0o755)
      assert Store.read(store) == before
    end
  end

  describe "default server argument (the named singleton)" do
    test "read/0 and set_issue_state/2 default to SymphonyElixir.Local.Store when no server is given", %{data_path: data_path} do
      establish!(data_path, %{"1" => %{"state" => "todo"}})

      {:ok, pid} = Store.start_link(path: data_path, name: SymphonyElixir.Local.Store)

      assert {:ok, %{issues: %{"1" => %{"state" => "todo"}}}} = Store.read()
      assert {:ok, %{"state" => "in_progress"}} = Store.set_issue_state("1", "in_progress")

      GenServer.stop(pid)
    end
  end
end
