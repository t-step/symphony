defmodule SymphonyElixir.Bindle.OwnerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Bindle.Owner

  setup do
    dir = Path.join(System.tmp_dir!(), "bindle-owner-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "owner_id")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, path: path}
  end

  test "generates and persists an opaque identity on first use", %{path: path} do
    refute File.exists?(path)
    assert {:ok, identity} = Owner.id(path)
    assert is_binary(identity)
    assert String.trim(identity) != ""
    assert File.exists?(path)
  end

  test "reuses the persisted identity on subsequent reads", %{path: path} do
    assert {:ok, first} = Owner.id(path)
    assert {:ok, second} = Owner.id(path)
    assert first == second
  end

  test "fails loud (does not regenerate) when the persisted file is empty", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")

    assert {:error, {:corrupt_owner_identity, ^path}} = Owner.id(path)

    # Confirm it truly did not silently regenerate: the file is still empty.
    assert File.read!(path) == ""
  end

  test "fails loud (does not regenerate) when the persisted file is whitespace-only", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "   \n")

    assert {:error, {:corrupt_owner_identity, ^path}} = Owner.id(path)
  end

  test "surfaces a non-enoent read failure as a distinguishable corrupt-identity error" do
    # A directory at the "file" path produces :eisdir, not :enoent — a genuinely different failure
    # from "does not exist yet" and must not be treated as first-use (never silently create/overwrite
    # a directory).
    dir_as_path = Path.join(System.tmp_dir!(), "bindle-owner-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir_as_path)
    on_exit(fn -> File.rm_rf(dir_as_path) end)

    assert {:error, {:corrupt_owner_identity, ^dir_as_path, :eisdir}} = Owner.id(dir_as_path)
  end

  test "surfaces a write failure on first use as a distinguishable error, not a silent success", %{path: path} do
    parent = Path.dirname(path)
    File.mkdir_p!(parent)
    File.chmod!(parent, 0o555)
    on_exit(fn -> File.chmod!(parent, 0o755) end)

    assert {:error, {:owner_identity_write_failed, ^path, :eacces}} = Owner.id(path)
  end
end
