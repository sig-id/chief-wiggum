defmodule Indexer.Workers.Lifecycle do
  @moduledoc """
  Worker lifecycle transition table.

  This is a compact Elixir version of the state families carried over from
  `formal/WorkerLifecycle.tla`.
  """

  @initial "none"
  @terminal MapSet.new(["merged", "failed"])

  @transitions %{
    "worker.spawned" => %{"none" => "needs_merge"},
    "fix.detected" => %{
      "none" => "needs_fix",
      "needs_merge" => "needs_fix",
      "failed" => "needs_fix"
    },
    "fix.started" => %{"needs_fix" => "fixing"},
    "fix.pass" => %{"fixing" => "needs_merge"},
    "fix.skip" => %{"fixing" => "needs_merge"},
    "fix.partial" => %{"fixing" => "needs_fix"},
    "fix.timeout" => %{"fixing" => "needs_fix"},
    "fix.fail" => %{"fixing" => "failed"},
    "fix.already_merged" => %{"needs_fix" => "merged", "fixing" => "merged"},
    "merge.start" => %{"needs_merge" => "merging"},
    "merge.succeeded" => %{"merging" => "merged"},
    "merge.already_merged" => %{"needs_merge" => "merged", "merging" => "merged"},
    "merge.conflict" => %{"merging" => "merge_conflict"},
    "merge.out_of_date" => %{"merging" => "needs_fix"},
    "merge.transient_fail" => %{"merging" => "needs_merge"},
    "merge.hard_fail" => %{"merging" => "failed"},
    "conflict.needs_resolve" => %{"merge_conflict" => "needs_resolve"},
    "conflict.needs_multi" => %{"merge_conflict" => "needs_multi_resolve"},
    "resolve.started" => %{"needs_resolve" => "resolving", "needs_multi_resolve" => "resolving"},
    "resolve.succeeded" => %{"resolving" => "needs_merge"},
    "resolve.fail" => %{"resolving" => "failed"},
    "resolve.timeout" => %{"resolving" => "needs_resolve"},
    "resolve.already_merged" => %{"resolving" => "merged"},
    "change_set.merged" => %{
      "none" => "merged",
      "needs_merge" => "merged",
      "merging" => "merged",
      "failed" => "merged"
    },
    "worker.failure" => %{"fixing" => "failed", "merging" => "failed", "resolving" => "failed"},
    "startup.reset" => %{
      "fixing" => "needs_fix",
      "merging" => "needs_merge",
      "resolving" => "needs_resolve"
    },
    "user.full_reset" => %{"failed" => "none", "merged" => "none"},
    "user.reset_to_fix" => %{"failed" => "needs_fix"},
    "user.reset_to_resolve" => %{"failed" => "needs_resolve"}
  }

  @doc """
  Computes the next state for an event.
  """
  @spec next_state(String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, {:invalid_transition, String.t(), String.t()}}
  def next_state(nil, event_type), do: next_state(@initial, event_type)

  def next_state(state, event_type) when is_binary(state) and is_binary(event_type) do
    @transitions
    |> Map.get(event_type, %{})
    |> Map.fetch(state)
    |> case do
      {:ok, next} -> {:ok, next}
      :error -> {:error, {:invalid_transition, state, event_type}}
    end
  end

  @spec terminal?(String.t()) :: boolean()
  def terminal?(state) when is_binary(state), do: MapSet.member?(@terminal, state)
  def terminal?(_state), do: false
end
