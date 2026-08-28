defmodule SymphonyElixir.Tracker.IssueTest do
  use SymphonyElixir.TestSupport

  test "continuation_allowed defaults to true" do
    assert %Issue{}.continuation_allowed == true
    assert %Issue{continuation_allowed: false}.continuation_allowed == false
  end

  test "dispatchable?/1 reads only issue.dispatchable, ignoring labels/continuation_allowed" do
    assert Issue.dispatchable?(%Issue{dispatchable: true})
    refute Issue.dispatchable?(%Issue{dispatchable: false})
    refute Issue.dispatchable?(%Issue{dispatchable: nil})

    # Labels/continuation_allowed never affect the admission concern.
    assert Issue.dispatchable?(%Issue{dispatchable: true, labels: [], continuation_allowed: false})
    refute Issue.dispatchable?(%Issue{dispatchable: false, labels: ["x"], continuation_allowed: true})
  end

  test "routed?/2 reads label match and continuation_allowed, ignoring dispatchable" do
    routed_issue = %Issue{labels: ["symphony", "javascript"], continuation_allowed: true}

    # dispatchable: false (the struct default) never affects routing.
    assert Issue.routed?(routed_issue, [])
    assert Issue.routed?(routed_issue, ["symphony"])
    assert Issue.routed?(%{routed_issue | dispatchable: true}, ["symphony"])
    refute Issue.routed?(routed_issue, ["security"])

    # continuation_allowed: false stops routing regardless of label match.
    refute Issue.routed?(%{routed_issue | continuation_allowed: false}, [])
    refute Issue.routed?(%{routed_issue | continuation_allowed: false, dispatchable: true}, [])

    # A non-list required_labels argument fails safe (false), matching routable?/2's own
    # long-standing guard-failure behavior for the analogous case.
    refute Issue.routed?(routed_issue, nil)
    refute Issue.routed?(%{routed_issue | labels: nil}, [])
  end

  test "routable?/2 remains the dispatchable?/1 and routed?/2 composition (existing callers unaffected)" do
    issue = %Issue{labels: ["symphony"], dispatchable: true, continuation_allowed: true}

    assert Issue.routable?(issue, ["symphony"])
    refute Issue.routable?(%{issue | dispatchable: false}, ["symphony"])
    refute Issue.routable?(%{issue | continuation_allowed: false}, ["symphony"])
    refute Issue.routable?(issue, ["security"])
  end
end
