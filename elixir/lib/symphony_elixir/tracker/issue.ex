defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Normalized work item representation used by the orchestrator.

  `id` is the stable dispatch identity for the configured tracker scope. It may
  differ from a provider's underlying issue ID when the scheduled item is a
  board or project entry. `native_ref` carries non-secret provider identifiers
  needed by provider-native agent tools. `identifier` remains the human-readable
  value used to derive the workspace key and must be unique within that scope.
  """

  defstruct [
    :id,
    :native_ref,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    dispatchable: false,
    continuation_allowed: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          native_ref: map() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          blocked_by: [map()],
          dispatchable: boolean(),
          continuation_allowed: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @doc """
  The admission concern alone: whether the tracker's own precomputed fact says this issue is
  currently eligible to be newly dispatched. Never consulted for continuation of an issue Symphony
  already has running/blocked state for (see `routed?/2`).
  """
  @spec dispatchable?(t()) :: boolean()
  def dispatchable?(%__MODULE__{dispatchable: dispatchable}), do: dispatchable == true

  @doc """
  The continuation/routing concern alone: label match against `required_labels`, plus
  `continuation_allowed` — a provider-neutral fact some adapters populate (Linear: still assigned to
  this worker; Asana: not yet completed) that continuation should stop even though label match alone
  would not catch it. Never consults `dispatchable`.
  """
  @spec routed?(t(), [String.t()]) :: boolean()
  def routed?(%__MODULE__{labels: labels, continuation_allowed: continuation_allowed}, required_labels)
      when is_list(labels) and is_list(required_labels) do
    continuation_allowed == true and label_match?(labels, required_labels)
  end

  def routed?(%__MODULE__{}, _required_labels), do: false

  @doc """
  Admission composed with routing — `dispatchable?/1 and routed?/2` — used only by the legitimate
  fresh-admission caller (`candidate_issue?/3`), never by a continuation-mode re-validation.
  """
  @spec routable?(t(), [String.t()]) :: boolean()
  def routable?(%__MODULE__{} = issue, required_labels) do
    dispatchable?(issue) and routed?(issue, required_labels)
  end

  defp label_match?(labels, required_labels) do
    issue_labels = MapSet.new(labels, &normalize_label/1)
    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end
end
