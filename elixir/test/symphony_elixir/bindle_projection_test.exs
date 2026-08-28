defmodule SymphonyElixir.Bindle.ProjectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Bindle.Projection

  setup do
    path =
      Path.join(System.tmp_dir!(), "bindle-projection-#{System.unique_integer([:positive])}.sqlite3")

    on_exit(fn -> File.rm(path) end)

    {:ok, path: path}
  end

  test "open_and_validate/1 succeeds against a correctly-versioned projection", %{path: path} do
    build_projection!(path, [])
    assert :ok = Projection.open_and_validate(path)
  end

  test "open_and_validate/1 fails loud on a missing file", %{path: path} do
    assert {:error, _reason} = Projection.open_and_validate(path)
  end

  test "open_and_validate/1 fails loud on an unsupported schema version", %{path: path} do
    build_projection!(path, [], schema_version: 2)
    assert {:error, {:unsupported_projection_version, 2}} = Projection.open_and_validate(path)
  end

  test "open_and_validate/1 fails loud on a file that is not a valid SQLite database", %{path: path} do
    File.write!(path, "this is not a sqlite file, just garbage bytes")

    assert {:error, {:bindle_projection_query_failed, _reason}} = Projection.open_and_validate(path)
  end

  test "fetch_by_ids/2 fails loud (via the rescue path) when given a query parameter of an unsupported type",
       %{path: path} do
    build_projection!(path, [])

    assert {:error, {:bindle_projection_query_failed, _reason}} = Projection.fetch_by_ids(path, [%{bad: "shape"}])
  end

  test "fetch_by_states/2 maps rows onto Tracker.Issue verbatim, leaving unpublished fields at their default", %{
    path: path
  } do
    build_projection!(path, [
      %{
        id: "task-1",
        identifier: "T-1",
        title: "Do the thing",
        description: "A description",
        status: "open",
        dispatchable: 1,
        created_at: "2026-01-01T00:00:00Z"
      },
      %{
        id: "task-2",
        identifier: "T-2",
        title: "Other",
        description: nil,
        status: "done",
        dispatchable: 0,
        created_at: "2026-01-02T00:00:00Z"
      }
    ])

    assert {:ok, [issue]} = Projection.fetch_by_states(path, ["open"])
    assert issue.id == "task-1"
    assert issue.identifier == "T-1"
    assert issue.title == "Do the thing"
    assert issue.description == "A description"
    assert issue.state == "open"
    assert issue.dispatchable == true
    assert issue.created_at == ~U[2026-01-01 00:00:00Z]

    # Every unpublished field stays at its existing struct default.
    assert issue.native_ref == nil
    assert issue.priority == nil
    assert issue.branch_name == nil
    assert issue.url == nil
    assert issue.assignee_id == nil
    assert issue.labels == []
    assert issue.blocked_by == []
    assert issue.updated_at == nil
    assert issue.continuation_allowed == true

    assert {:ok, [done_issue]} = Projection.fetch_by_states(path, ["done"])
    assert done_issue.id == "task-2"
    assert done_issue.dispatchable == false
    assert done_issue.description == nil
  end

  test "fetch_by_states/2 and fetch_by_ids/2 return {:ok, []} for an empty query without touching the file", %{
    path: path
  } do
    assert {:ok, []} = Projection.fetch_by_states(path, [])
    assert {:ok, []} = Projection.fetch_by_ids(path, [])
  end

  test "fetch_by_ids/2 queries by column name and returns {:ok, []} for a genuinely empty result", %{path: path} do
    build_projection!(path, [
      %{
        id: "task-1",
        identifier: "T-1",
        title: "Do the thing",
        description: nil,
        status: "open",
        dispatchable: 1,
        created_at: "2026-01-01T00:00:00Z"
      }
    ])

    assert {:ok, [issue]} = Projection.fetch_by_ids(path, ["task-1"])
    assert issue.id == "task-1"

    assert {:ok, []} = Projection.fetch_by_ids(path, ["does-not-exist"])
  end

  test "fetch_by_states/2 fails loud (never silently drops) on a structurally invalid row", %{path: path} do
    build_projection!(path, [
      %{
        id: "task-1",
        identifier: "T-1",
        title: "Valid",
        description: nil,
        status: "open",
        dispatchable: 1,
        created_at: "2026-01-01T00:00:00Z"
      },
      %{
        # title is nullable in Bindle's real schema, but Symphony's own minimum-shape requirement
        # treats a missing title as an affected-fetch failure, never a silently-dropped row.
        id: "task-2",
        identifier: "T-2",
        title: nil,
        description: nil,
        status: "open",
        dispatchable: 1,
        created_at: "2026-01-01T00:00:00Z"
      }
    ])

    assert {:error, _reason} = Projection.fetch_by_states(path, ["open"])
  end

  test "fetch_by_states/2 fails loud on an unparseable created_at", %{path: path} do
    build_projection!(path, [
      %{
        id: "task-1",
        identifier: "T-1",
        title: "Valid",
        description: nil,
        status: "open",
        dispatchable: 1,
        created_at: "not-a-date"
      }
    ])

    assert {:error, _reason} = Projection.fetch_by_states(path, ["open"])
  end

  test "list_ids/1 returns every id regardless of dispatchable, performing no lifecycle interpretation", %{
    path: path
  } do
    build_projection!(path, [
      %{
        id: "task-1",
        identifier: "T-1",
        title: "Open",
        description: nil,
        status: "open",
        dispatchable: 1,
        created_at: "2026-01-01T00:00:00Z"
      },
      %{
        id: "task-2",
        identifier: "T-2",
        title: "Claimed",
        description: nil,
        status: "open",
        dispatchable: 0,
        created_at: "2026-01-01T00:00:00Z"
      },
      %{
        id: "task-3",
        identifier: "T-3",
        title: "Done",
        description: nil,
        status: "done",
        dispatchable: 0,
        created_at: "2026-01-01T00:00:00Z"
      }
    ])

    assert {:ok, ids} = Projection.list_ids(path)
    assert Enum.sort(ids) == ["task-1", "task-2", "task-3"]
  end

  test "list_ids/1 surfaces the same distinguishable failure as the other functions on a missing/incompatible projection",
       %{path: path} do
    assert {:error, _reason} = Projection.list_ids(path)

    build_projection!(path, [], schema_version: 2)
    assert {:error, {:unsupported_projection_version, 2}} = Projection.list_ids(path)
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
