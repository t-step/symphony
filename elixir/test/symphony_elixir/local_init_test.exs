defmodule SymphonyElixir.LocalInitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Local.Init
  alias SymphonyElixir.Local.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-local-init-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    data_path = Path.join(dir, ".symphony/local_tracker.json")
    marker_path = Store.marker_path(data_path)

    on_exit(fn ->
      File.chmod(dir, 0o755)
      File.chmod(Path.dirname(data_path), 0o755)
      File.rm_rf!(dir)
    end)

    %{dir: dir, data_path: data_path, marker_path: marker_path}
  end

  defp read_established_at(marker_path) do
    marker_path |> File.read!() |> Jason.decode!() |> Map.fetch!("established_at")
  end

  describe "fresh initialization" do
    test "creates the data file then the marker, both valid, under a not-yet-existing parent directory", %{data_path: data_path, marker_path: marker_path} do
      refute File.exists?(Path.dirname(data_path))

      assert {:ok, :initialized} = Init.run(data_path)

      assert %{"format_version" => 1, "issues" => %{}} = data_path |> File.read!() |> Jason.decode!()
      assert %{"established_at" => established_at} = marker_path |> File.read!() |> Jason.decode!()
      assert is_binary(established_at)
    end
  end

  describe "already-established store" do
    test "refuses without --reset and leaves both files untouched (idempotent no-op re-run)", %{data_path: data_path, marker_path: marker_path} do
      assert {:ok, :initialized} = Init.run(data_path)

      original_data = File.read!(data_path)
      original_marker = File.read!(marker_path)

      assert {:error, :already_established} = Init.run(data_path)
      assert File.read!(data_path) == original_data
      assert File.read!(marker_path) == original_marker
    end

    test "refuses without --reset when the marker is present but the data file is missing (FR-013 loss)", %{data_path: data_path, marker_path: marker_path} do
      File.mkdir_p!(Path.dirname(marker_path))
      File.write!(marker_path, Jason.encode!(%{"established_at" => "2026-01-01T00:00:00Z"}))

      assert {:error, :already_established} = Init.run(data_path)
      refute File.exists?(data_path)
    end

    test "refuses without --reset when the marker exists but is unreadable (a directory, not a file)", %{data_path: data_path, marker_path: marker_path} do
      File.mkdir_p!(marker_path)

      assert {:error, {:marker_unreadable, _reason}} = Init.run(data_path)
      refute File.exists?(data_path)
    end
  end

  describe "ambiguous state (data present, marker missing) — the sanctioned recovery path" do
    test "completes establishment by writing only the marker; the data file is byte-for-byte unchanged", %{data_path: data_path, marker_path: marker_path} do
      File.mkdir_p!(Path.dirname(data_path))
      original_content = Jason.encode!(%{"format_version" => 1, "issues" => %{"1" => %{"state" => "todo"}}})
      File.write!(data_path, original_content)
      refute File.exists?(marker_path)

      assert {:ok, :marker_completed} = Init.run(data_path)

      assert File.read!(data_path) == original_content
      assert {"established_at", established_at} = {"established_at", read_established_at(marker_path)}
      assert is_binary(established_at)
    end

    test "re-running init again after completion refuses (now genuinely established)", %{data_path: data_path} do
      File.mkdir_p!(Path.dirname(data_path))
      File.write!(data_path, Jason.encode!(%{"format_version" => 1, "issues" => %{}}))

      assert {:ok, :marker_completed} = Init.run(data_path)
      assert {:error, :already_established} = Init.run(data_path)
    end

    test "refuses with a clear error when the data file is present but does not parse, and creates no marker", %{data_path: data_path, marker_path: marker_path} do
      File.mkdir_p!(Path.dirname(data_path))
      File.write!(data_path, "not valid json")

      assert {:error, {:unparseable_data_file, _reason}} = Init.run(data_path)
      refute File.exists?(marker_path)
      assert File.read!(data_path) == "not valid json"
    end

    test "surfaces a write failure when completing establishment fails (unwritable parent directory)", %{data_path: data_path, marker_path: marker_path} do
      parent = Path.dirname(data_path)
      File.mkdir_p!(parent)
      File.write!(data_path, Jason.encode!(%{"format_version" => 1, "issues" => %{}}))
      File.chmod!(parent, 0o500)

      assert {:error, _reason} = Init.run(data_path)

      File.chmod!(parent, 0o755)
      refute File.exists?(marker_path)
    end
  end

  describe "--reset" do
    test "deletes both files (if present) and recreates a fresh, valid pair", %{data_path: data_path, marker_path: marker_path} do
      assert {:ok, :initialized} = Init.run(data_path)

      {:ok, store} = Store.start_link(path: data_path)
      assert {:error, :issue_not_found} = Store.set_issue_state(store, "1", "todo")
      File.write!(data_path, Jason.encode!(%{"format_version" => 1, "issues" => %{"1" => %{"state" => "todo"}}}))

      assert {:ok, :reset} = Init.run(data_path, reset: true)

      assert %{"format_version" => 1, "issues" => %{}} = data_path |> File.read!() |> Jason.decode!()
      assert File.exists?(marker_path)
    end

    test "works even when neither file previously existed", %{data_path: data_path, marker_path: marker_path} do
      refute File.exists?(data_path)

      assert {:ok, :reset} = Init.run(data_path, reset: true)

      assert File.exists?(data_path)
      assert File.exists?(marker_path)
    end

    test "works when the store was only ambiguous (data present, marker missing)", %{data_path: data_path, marker_path: marker_path} do
      File.mkdir_p!(Path.dirname(data_path))
      File.write!(data_path, Jason.encode!(%{"format_version" => 1, "issues" => %{"stale" => %{"state" => "todo"}}}))

      assert {:ok, :reset} = Init.run(data_path, reset: true)

      assert %{"format_version" => 1, "issues" => %{}} = data_path |> File.read!() |> Jason.decode!()
      assert File.exists?(marker_path)
    end

    test "surfaces a delete failure (unwritable parent directory) and leaves the established store intact", %{data_path: data_path, marker_path: marker_path} do
      assert {:ok, :initialized} = Init.run(data_path)
      original_data = File.read!(data_path)
      original_marker = File.read!(marker_path)

      parent = Path.dirname(data_path)
      File.chmod!(parent, 0o500)

      assert {:error, _reason} = Init.run(data_path, reset: true)

      File.chmod!(parent, 0o755)
      assert File.read!(data_path) == original_data
      assert File.read!(marker_path) == original_marker
    end
  end

  describe "atomic-write / failure behavior" do
    test "a write failure (unwritable parent directory) leaves no partial state behind", %{data_path: data_path} do
      parent = Path.dirname(data_path)
      File.mkdir_p!(parent)
      File.chmod!(parent, 0o500)

      assert {:error, _reason} = Init.run(data_path)

      File.chmod!(parent, 0o755)
      refute File.exists?(data_path)
    end

    test "resolves a relative path the same way as an absolute one", %{dir: dir} do
      data_path = Path.join(dir, "relative/local_tracker.json")
      assert {:ok, :initialized} = Init.run(data_path)
      assert File.exists?(data_path)
    end
  end
end
