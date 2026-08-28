defmodule SymphonyElixir.TrackerTest do
  use SymphonyElixir.TestSupport

  @existing_adapter_kinds ~w(asana github gitlab jira linear local)

  test "acquire_issue/2 and release_issue/2 are complete no-ops for every existing adapter" do
    Enum.each(@existing_adapter_kinds, fn kind ->
      assert {:ok, adapter_module} = Tracker.adapter_for_kind(kind)

      refute function_exported?(adapter_module, :acquire_issue, 2),
             "#{inspect(adapter_module)} (#{kind}) must not implement acquire_issue/2"

      refute function_exported?(adapter_module, :release_issue, 2),
             "#{inspect(adapter_module)} (#{kind}) must not implement release_issue/2"
    end)
  end

  test "Tracker.acquire_issue/2 and Tracker.release_issue/2 resolve to :ok when the active adapter has no implementation" do
    # The default TestSupport workflow selects tracker.kind: linear, which does not implement
    # the optional acquisition/release seam.
    issue = %Issue{id: "issue-1", identifier: "LIN-1", title: "Test issue"}

    assert :ok = Tracker.acquire_issue(issue)
    assert :ok = Tracker.acquire_issue(issue, worktree: "/tmp/should-be-ignored")
    assert :ok = Tracker.release_issue("issue-1")
    assert :ok = Tracker.release_issue("issue-1", [])
  end
end
