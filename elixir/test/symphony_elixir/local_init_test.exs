defmodule SymphonyElixir.LocalInitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Local.Init
  alias SymphonyElixir.Local.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-local-init-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    data_path = Path.join(dir, ".symphony/local_tracker.db")

    on_exit(fn ->
      File.chmod(dir, 0o755)
      File.chmod(Path.dirname(data_path), 0o755)
      File.rm_rf!(dir)
    end)

    %{dir: dir, data_path: data_path}
  end

  describe "fresh initialization" do
    test "creates the database under a not-yet-existing parent directory, with a valid, empty schema", %{
      data_path: data_path
    } do
      refute File.exists?(Path.dirname(data_path))

      assert {:ok, :initialized} = Init.run(data_path)

      assert File.regular?(data_path)
      assert {:ok, %{issues: %{}}} = Store.evaluate(data_path)
    end
  end

  describe "already-established store" do
    test "refuses without --reset and leaves the database untouched (idempotent no-op re-run)", %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)
      original = File.read!(data_path)

      assert {:error, :already_established} = Init.run(data_path)
      assert File.read!(data_path) == original
    end

    test "refuses without --reset even when the established database is corrupt", %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)
      File.write!(data_path, "not a sqlite database")

      assert {:error, :already_established} = Init.run(data_path)
      assert File.read!(data_path) == "not a sqlite database"
    end

    test "refuses without --reset when a database file exists but was never marked established (FR-013's inconsistent-state case)",
         %{data_path: data_path} do
      File.mkdir_p!(Path.dirname(data_path))
      File.write!(data_path, "not a sqlite database")

      assert {:error, {:ambiguous_local_tracker_state, :marker_missing}} = Init.run(data_path)
      assert File.read!(data_path) == "not a sqlite database"
    end

    test "refuses without --reset when the marker is present but the database file is missing (FR-013 established-state loss)",
         %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)
      File.rm!(data_path)

      assert {:error, :already_established} = Init.run(data_path)
      refute File.exists?(data_path)
    end
  end

  describe "--reset" do
    test "deletes the existing database (if present) and recreates a fresh, valid one", %{data_path: data_path} do
      assert {:ok, :initialized} = Init.run(data_path)

      {:ok, store} = Store.start_link(path: data_path)
      assert {:error, :issue_not_found} = Store.set_issue_state(store, "1", "todo")
      GenServer.stop(store)

      {:ok, conn} = Exqlite.Basic.open(data_path)
      {:ok, _rows, _cols} = Exqlite.Basic.exec(conn, "INSERT INTO work_items (id, state) VALUES ('1', 'todo')") |> Exqlite.Basic.rows()
      :ok = Exqlite.Basic.close(conn)

      assert {:ok, :reset} = Init.run(data_path, reset: true)

      assert {:ok, %{issues: %{}}} = Store.evaluate(data_path)
    end

    test "works even when nothing previously existed", %{data_path: data_path} do
      refute File.exists?(data_path)

      assert {:ok, :reset} = Init.run(data_path, reset: true)

      assert {:ok, %{issues: %{}}} = Store.evaluate(data_path)
    end

    test "works when the existing file was not a valid SQLite database", %{data_path: data_path} do
      File.mkdir_p!(Path.dirname(data_path))
      File.write!(data_path, "not a sqlite database")

      assert {:ok, :reset} = Init.run(data_path, reset: true)

      assert {:ok, %{issues: %{}}} = Store.evaluate(data_path)
    end

    test "surfaces a delete failure (unwritable parent directory) and leaves the established store intact", %{
      data_path: data_path
    } do
      assert {:ok, :initialized} = Init.run(data_path)
      original = File.read!(data_path)

      parent = Path.dirname(data_path)
      File.chmod!(parent, 0o500)

      assert {:error, _reason} = Init.run(data_path, reset: true)

      File.chmod!(parent, 0o755)
      assert File.read!(data_path) == original
    end
  end

  describe "write-failure behavior" do
    test "a write failure (unwritable parent directory) leaves no partial state behind", %{data_path: data_path} do
      parent = Path.dirname(data_path)
      File.mkdir_p!(parent)
      File.chmod!(parent, 0o500)

      assert {:error, _reason} = Init.run(data_path)

      File.chmod!(parent, 0o755)
      refute File.exists?(data_path)
      refute File.exists?(Store.marker_path(data_path))
    end

    test "a failure to even create the parent directory tree leaves no partial state behind", %{dir: dir} do
      grandparent = Path.join(dir, "grandparent")
      File.mkdir_p!(grandparent)
      File.chmod!(grandparent, 0o500)

      data_path = Path.join(grandparent, "not-yet-created/local_tracker.db")

      assert {:error, _reason} = Init.run(data_path)

      File.chmod!(grandparent, 0o755)
      refute File.exists?(Path.dirname(data_path))
    end

    test "resolves a relative path the same way as an absolute one", %{dir: dir} do
      data_path = Path.join(dir, "relative/local_tracker.db")
      assert {:ok, :initialized} = Init.run(data_path)
      assert File.exists?(data_path)
    end
  end
end
