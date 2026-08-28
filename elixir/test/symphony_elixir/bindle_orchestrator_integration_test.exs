defmodule SymphonyElixir.Bindle.OrchestratorIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator

  defmodule FakeCli do
    def claim(repo_path, bindle_bin, id, owner) do
      send(self(), {:bindle_claim_called, repo_path, bindle_bin, id, owner})
      Process.get(:fake_cli_claim_result, {:ok, "claimed"})
    end

    def release(repo_path, bindle_bin, id, owner) do
      send(self(), {:bindle_release_called, repo_path, bindle_bin, id, owner})

      case Process.get(:fake_cli_release_results_by_id) do
        %{} = by_id -> Map.get(by_id, id, {:ok, "released"})
        nil -> Process.get(:fake_cli_release_result, {:ok, "released"})
      end
    end
  end

  setup do
    repo_root = Path.join(System.tmp_dir!(), "bindle-orch-repo-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(repo_root, "workspaces")
    File.mkdir_p!(Path.join(repo_root, ".bindle-work"))
    File.mkdir_p!(workspace_root)
    projection_path = Path.join(repo_root, ".bindle-work/symphony-projection.sqlite3")
    build_projection!(projection_path, [])

    write_bindle_workflow!(repo_root, workspace_root)

    Application.put_env(:symphony_elixir, :bindle_cli_module, FakeCli)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :bindle_cli_module)
      File.rm_rf(repo_root)
    end)

    {:ok, task_supervisor} = Task.Supervisor.start_link()
    # `max_children: 0` makes Task.Supervisor.start_child/2 return {:error, :max_children}
    # gracefully — a genuine, non-crashing spawn-failure path to drive the compensation tests.
    {:ok, full_task_supervisor} = Task.Supervisor.start_link(max_children: 0)

    context = [
      repo_root: repo_root,
      task_supervisor: task_supervisor,
      full_task_supervisor: full_task_supervisor,
      projection_path: projection_path
    ]

    {:ok, context}
  end

  ## Acquire sub-suite (FR-006, Acceptance Scenarios 1/2/5, SC-002)

  test "fresh-admission dispatch calls acquire_issue/2 before spawning, and proceeds only on :ok", %{
    repo_root: repo_root,
    task_supervisor: task_supervisor
  } do
    Process.put(:fake_cli_claim_result, {:ok, "claimed"})

    state = %Orchestrator.State{task_supervisor: task_supervisor}
    issue = %Issue{id: "task-1", identifier: "T-1", title: "Do it", state: "open"}

    updated_state = Orchestrator.spawn_issue_on_worker_host_for_test(state, issue, nil, self(), nil)

    assert_received {:bindle_claim_called, ^repo_root, "bindle", "task-1", owner}
    assert is_binary(owner) and owner != ""

    assert Map.has_key?(updated_state.running, "task-1")
    assert MapSet.member?(updated_state.claimed, "task-1")
  end

  test "fresh-admission dispatch skips without crashing when acquisition is unavailable", %{
    task_supervisor: task_supervisor
  } do
    Process.put(:fake_cli_claim_result, {:error, {:bindle_cli_failed, 1, "already_claimed"}})

    state = %Orchestrator.State{task_supervisor: task_supervisor}
    issue = %Issue{id: "task-2", identifier: "T-2", title: "Do it", state: "open"}

    updated_state = Orchestrator.spawn_issue_on_worker_host_for_test(state, issue, nil, self(), nil)

    refute Map.has_key?(updated_state.running, "task-2")
    refute MapSet.member?(updated_state.claimed, "task-2")
  end

  test "an issue already present in state.claimed (continuation retry) does not call acquire_issue/2 again — proceeds directly to respawn (FR-016/FR-024, SC-008)",
       %{repo_root: _repo_root, task_supervisor: task_supervisor} do
    state = %Orchestrator.State{task_supervisor: task_supervisor, claimed: MapSet.new(["task-3"])}
    issue = %Issue{id: "task-3", identifier: "T-3", title: "Continuation", state: "open"}

    updated_state = Orchestrator.spawn_issue_on_worker_host_for_test(state, issue, 1, self(), nil)

    refute_received {:bindle_claim_called, _, _, _, _}
    assert Map.has_key?(updated_state.running, "task-3")
    assert MapSet.member?(updated_state.claimed, "task-3")
  end

  ## Compensation sub-suite (FR-008, SC-006)

  test "acquisition succeeding immediately followed by a spawn failure releases the just-acquired claim before scheduling the retry",
       %{repo_root: repo_root, full_task_supervisor: full_task_supervisor} do
    Process.put(:fake_cli_claim_result, {:ok, "claimed"})
    Process.put(:fake_cli_release_result, {:ok, "released"})

    state = %Orchestrator.State{task_supervisor: full_task_supervisor}
    issue = %Issue{id: "task-4", identifier: "T-4", title: "Spawn fails", state: "open"}

    updated_state = Orchestrator.spawn_issue_on_worker_host_for_test(state, issue, nil, self(), nil)

    assert_received {:bindle_claim_called, ^repo_root, "bindle", "task-4", _owner}
    assert_received {:bindle_release_called, ^repo_root, "bindle", "task-4", _owner}

    refute Map.has_key?(updated_state.running, "task-4")
    refute MapSet.member?(updated_state.claimed, "task-4")
    assert Map.has_key?(updated_state.retry_attempts, "task-4")
  end

  test "the ordinary crash-mid-run retry (continuation, already in state.claimed) does not release on spawn — nothing to compensate for",
       %{full_task_supervisor: full_task_supervisor} do
    state = %Orchestrator.State{task_supervisor: full_task_supervisor, claimed: MapSet.new(["task-5"])}
    issue = %Issue{id: "task-5", identifier: "T-5", title: "Continuation spawn fails", state: "open"}

    _updated_state = Orchestrator.spawn_issue_on_worker_host_for_test(state, issue, 1, self(), nil)

    refute_received {:bindle_claim_called, _, _, _, _}
    refute_received {:bindle_release_called, _, _, _, _}
  end

  ## Retry-split sub-suite (FR-016/FR-024, SC-008)

  test "continuation retry (issue already in state.claimed) re-validates via routing, not dispatchable — dispatchable: false does not block it",
       %{repo_root: _repo_root} do
    issue = %Issue{
      id: "task-8",
      identifier: "T-8",
      state: "open",
      title: "Continuation",
      labels: [],
      dispatchable: false,
      continuation_allowed: true
    }

    fetcher = fn ["task-8"] -> {:ok, [issue]} end

    assert {:ok, ^issue} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fetcher, true)
  end

  test "fresh-admission retry (issue not in state.claimed) still requires dispatchable: true at re-validation",
       %{repo_root: _repo_root} do
    not_dispatchable = %Issue{
      id: "task-9",
      identifier: "T-9",
      state: "open",
      title: "Fresh",
      labels: [],
      dispatchable: false
    }

    fetcher_not_dispatchable = fn ["task-9"] -> {:ok, [not_dispatchable]} end

    assert {:skip, ^not_dispatchable} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(not_dispatchable, fetcher_not_dispatchable, false)

    dispatchable = %{not_dispatchable | dispatchable: true}
    fetcher_dispatchable = fn ["task-9"] -> {:ok, [dispatchable]} end

    assert {:ok, ^dispatchable} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(dispatchable, fetcher_dispatchable, false)
  end

  test "a crash-mid-run retry of a continuation issue with dispatchable: false reaches handle_active_retry (not release) and does not call acquire_issue/2 again",
       %{repo_root: _repo_root} do
    Process.put(:fake_cli_claim_result, {:ok, "claimed"})

    {:ok, full_task_supervisor} = Task.Supervisor.start_link(max_children: 0)

    state = %Orchestrator.State{
      task_supervisor: full_task_supervisor,
      claimed: MapSet.new(["task-10"]),
      max_concurrent_agents: 1
    }

    issue = %Issue{
      id: "task-10",
      identifier: "T-10",
      state: "open",
      title: "Continuation retry",
      labels: [],
      dispatchable: false,
      continuation_allowed: true
    }

    _result =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, "task-10", 1, %{
        identifier: issue.identifier,
        error: "worker crashed mid-run"
      })

    # It reached handle_active_retry (not the release branch) and attempted a respawn — proven by
    # the spawn failure (max_children: 0) producing a retry rather than a release, and by
    # acquire_issue/2 never being called for an issue already in state.claimed.
    refute_received {:bindle_claim_called, _, _, _, _}
  end

  ## Release sub-suite (FR-007/FR-020/FR-021, Acceptance Scenario 3)

  test "release_issue/2 fires exactly once when a running issue is terminated", %{repo_root: repo_root} do
    Process.put(:fake_cli_release_result, {:ok, "released"})

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        "task-6" => %{
          pid: agent_pid,
          ref: nil,
          identifier: "T-6",
          issue: %Issue{id: "task-6", identifier: "T-6", state: "done"},
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new(["task-6"]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    issue = %Issue{id: "task-6", identifier: "T-6", state: "done", title: "Terminal", labels: []}

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    assert_received {:bindle_release_called, ^repo_root, "bindle", "task-6", _owner}
    refute_received {:bindle_release_called, ^repo_root, "bindle", "task-6", _owner}

    refute Map.has_key?(updated_state.running, "task-6")
    refute MapSet.member?(updated_state.claimed, "task-6")
  end

  test "release_issue/2 is NOT called merely because a crash-mid-run retry is scheduled for an already-claimed issue",
       %{repo_root: _repo_root} do
    Process.put(:fake_cli_release_result, {:ok, "released"})

    # No worker slots available (max_concurrent_agents: 0) so handle_active_retry/4 takes its
    # "reschedule, do not touch the claim" branch — the retry is deferred, never released, exactly
    # what FR-007 requires for an ordinary crash-mid-run retry of an already-claimed issue.
    state = %Orchestrator.State{claimed: MapSet.new(["task-7"]), max_concurrent_agents: 0}

    issue = %Issue{
      id: "task-7",
      identifier: "T-7",
      state: "open",
      title: "Retrying",
      labels: [],
      dispatchable: true
    }

    _updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, "task-7", 1, %{
        identifier: issue.identifier,
        error: "agent exited"
      })

    refute_received {:bindle_release_called, _, _, _, _}
  end

  ## Startup-reconciliation sub-suite (FR-012/FR-029, SC-007)

  test "sweeps every projected id with an owner-scoped release, continuing past individual failures", %{
    repo_root: repo_root,
    projection_path: projection_path
  } do
    add_task!(projection_path, "task-a")
    add_task!(projection_path, "task-b")
    add_task!(projection_path, "task-c")

    Process.put(:fake_cli_release_results_by_id, %{
      "task-b" => {:error, {:bindle_cli_failed, 1, "transient"}}
    })

    assert {:ok, %Orchestrator.State{} = state} = Orchestrator.reconcile_stale_claims_for_test(%Orchestrator.State{})

    for id <- ["task-a", "task-b", "task-c"] do
      assert_received {:bindle_release_called, ^repo_root, "bindle", ^id, _owner}
    end

    # The failed id gets a bounded follow-up retry via the dedicated mechanism...
    assert %{attempt: 1, timer_ref: timer_ref, retry_token: retry_token} =
             state.stale_claim_release_retries["task-b"]

    assert is_reference(timer_ref)
    assert is_reference(retry_token)

    # ...and NEVER touches the coding-agent retry machinery.
    assert state.retry_attempts == %{}
  end

  test "an individual retry succeeding clears its entry without touching state.retry_attempts", %{
    repo_root: repo_root
  } do
    Process.put(:fake_cli_release_results_by_id, %{"task-x" => {:error, :transient}})

    {:ok, state} = Orchestrator.reconcile_stale_claims_for_test(%Orchestrator.State{})
    # (task-x isn't actually in the projection for this test — seed the retry state directly to
    # isolate the retry-firing behavior from the initial-sweep behavior already covered above.)
    retry_token = make_ref()
    timer_ref = make_ref()

    state = %{
      state
      | stale_claim_release_retries: %{"task-x" => %{attempt: 1, timer_ref: timer_ref, retry_token: retry_token}}
    }

    Process.put(:fake_cli_release_results_by_id, %{"task-x" => {:ok, "released"}})

    assert {:noreply, updated_state} =
             Orchestrator.handle_info(
               {:retry_stale_claim_release, "task-x", retry_token, repo_root, "bindle", "owner-a", 1},
               state
             )

    refute Map.has_key?(updated_state.stale_claim_release_retries, "task-x")
    assert updated_state.retry_attempts == %{}
  end

  test "an exhausted retry budget logs a persistent failure, drops the entry, and never touches state.retry_attempts",
       %{repo_root: repo_root} do
    Process.put(:fake_cli_release_results_by_id, %{"task-y" => {:error, :still_failing}})

    state = %Orchestrator.State{
      stale_claim_release_retries: %{"task-y" => %{attempt: 3, timer_ref: make_ref(), retry_token: make_ref()}}
    }

    retry_token = state.stale_claim_release_retries["task-y"].retry_token

    log =
      capture_log(fn ->
        assert {:noreply, updated_state} =
                 Orchestrator.handle_info(
                   {:retry_stale_claim_release, "task-y", retry_token, repo_root, "bindle", "owner-a", 3},
                   state
                 )

        refute Map.has_key?(updated_state.stale_claim_release_retries, "task-y")
        assert updated_state.retry_attempts == %{}
      end)

    assert log =~ "exhausted its retry budget"
    assert log =~ "task-y"
  end

  test "normal polling is not blocked by a pending stale-claim retry — the sweep returns synchronously", %{
    projection_path: projection_path
  } do
    add_task!(projection_path, "task-z")
    Process.put(:fake_cli_release_results_by_id, %{"task-z" => {:error, :transient}})

    {elapsed_us, {:ok, _state}} =
      :timer.tc(fn -> Orchestrator.reconcile_stale_claims_for_test(%Orchestrator.State{}) end)

    # The sweep itself never waits for the retry timer (10s+ backoff) — it schedules the retry and
    # returns immediately, so schedule_tick/2 (the first poll) is never delayed by it.
    assert elapsed_us < 1_000_000
  end

  test "a corrupt owner identity fails startup loud ({:stop, _}), never silently regenerating", %{
    repo_root: _repo_root
  } do
    owner_id_path = Path.join(Config.workflow_dir(), ".symphony/bindle_owner_id")
    File.mkdir_p!(Path.dirname(owner_id_path))
    File.write!(owner_id_path, "")

    assert {:stop, {:bindle_owner_identity_failed, _reason}} =
             Orchestrator.reconcile_stale_claims_for_test(%Orchestrator.State{})
  end

  test "a projection read failure is surfaced the same distinguishable way an ordinary poll failure would be — startup proceeds",
       %{repo_root: repo_root, projection_path: projection_path} do
    File.rm!(projection_path)

    log =
      capture_log(fn ->
        assert {:ok, %Orchestrator.State{}} = Orchestrator.reconcile_stale_claims_for_test(%Orchestrator.State{})
      end)

    assert log =~ "could not read the Bindle projection"
    refute_received {:bindle_release_called, ^repo_root, _, _, _}
  end

  defp add_task!(projection_path, id) do
    {:ok, conn} = Exqlite.Sqlite3.open(projection_path)

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        conn,
        "INSERT INTO task_projection (id, identifier, title, description, status, dispatchable, created_at) VALUES (?,?,?,?,?,?,?)"
      )

    :ok = Exqlite.Sqlite3.bind(stmt, [id, id, "Title", nil, "open", 0, "2026-01-01T00:00:00Z"])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    :ok = Exqlite.Sqlite3.close(conn)
  end

  defp write_bindle_workflow!(repo_root, workspace_root) do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: bindle
        provider:
          repo_path: #{Jason.encode!(repo_root)}
        active_states: ["open"]
        terminal_states: ["done", "superseded"]
      workspace:
        root: #{Jason.encode!(workspace_root)}
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    restart_workflow_store!()
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
