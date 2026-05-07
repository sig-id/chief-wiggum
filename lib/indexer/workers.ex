defmodule Indexer.Workers do
  @moduledoc """
  JSONL-backed worker lifecycle records.
  """

  alias Indexer.State.{Event, Jsonl}
  alias Indexer.Workers.Lifecycle

  @stream "workers"

  @doc """
  Spawns a worker record for a work item.
  """
  @spec spawn!(Path.t(), map(), keyword()) :: map()
  def spawn!(project_root, attrs, opts \\ []) when is_binary(project_root) and is_map(attrs) do
    attrs = Indexer.State.Json.normalize(attrs)
    worker_id = Map.get(attrs, "id") || new_worker_id(Map.fetch!(attrs, "work_item_id"))
    {:ok, state} = Lifecycle.next_state("none", "worker.spawned")

    payload =
      %{
        "id" => worker_id,
        "work_item_id" => Map.fetch!(attrs, "work_item_id"),
        "pipeline" => Map.get(attrs, "pipeline", "default"),
        "target_ref" => Map.get(attrs, "target_ref", "HEAD"),
        "work_branch" =>
          Map.get(attrs, "work_branch") ||
            "indexer/work/#{Map.fetch!(attrs, "work_item_id")}/#{worker_id}",
        "worker_dir" => Map.get(attrs, "worker_dir") || worker_dir(project_root, worker_id),
        "workspace_path" =>
          Map.get(attrs, "workspace_path") ||
            Path.join(worker_dir(project_root, worker_id), "workspace"),
        "state" => state,
        "lease" => Map.get(attrs, "lease", %{}),
        "spawned_at" => timestamp(),
        "metadata" => Map.get(attrs, "metadata", %{})
      }

    append_worker_event!(project_root, "worker.spawned", worker_id, payload, opts)
    payload
  end

  @doc """
  Applies a lifecycle transition to a worker.
  """
  @spec transition!(Path.t(), String.t(), String.t(), map(), keyword()) :: map()
  def transition!(project_root, worker_id, event_type, payload \\ %{}, opts \\ [])
      when is_binary(project_root) and is_binary(worker_id) and is_binary(event_type) and
             is_map(payload) do
    current_state = project_root |> get(worker_id) |> current_state()
    {:ok, next_state} = Lifecycle.next_state(current_state, event_type)

    payload =
      payload
      |> Indexer.State.Json.normalize()
      |> Map.merge(%{
        "id" => worker_id,
        "from_state" => current_state || "none",
        "state" => next_state,
        "transitioned_at" => timestamp()
      })

    append_worker_event!(project_root, event_type, worker_id, payload, opts)
    payload
  end

  @doc """
  Updates worker metadata without changing lifecycle state.
  """
  @spec update!(Path.t(), String.t(), map(), keyword()) :: map()
  def update!(project_root, worker_id, attrs, opts \\ [])
      when is_binary(project_root) and is_binary(worker_id) and is_map(attrs) do
    payload =
      attrs
      |> Indexer.State.Json.normalize()
      |> Map.put("id", worker_id)
      |> Map.put("updated_at", timestamp())

    append_worker_event!(project_root, "worker.updated", worker_id, payload, opts)
    payload
  end

  @doc """
  Folds worker events into current worker state.
  """
  @spec current(Path.t()) :: map()
  def current(project_root) when is_binary(project_root) do
    project_root
    |> Jsonl.ledger_path(@stream)
    |> Jsonl.read!()
    |> Enum.reduce(%{}, &fold_worker_event/2)
  end

  @doc """
  Gets a worker projection.
  """
  @spec get(Path.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(project_root, worker_id) when is_binary(project_root) and is_binary(worker_id) do
    case Map.fetch(current(project_root), worker_id) do
      {:ok, worker} -> {:ok, worker}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Lists workers in a specific lifecycle state.
  """
  @spec by_state(Path.t(), String.t()) :: [map()]
  def by_state(project_root, state) when is_binary(project_root) and is_binary(state) do
    project_root
    |> current()
    |> Map.values()
    |> Enum.filter(&(&1["state"] == state))
  end

  defp fold_worker_event(%{"type" => "worker.spawned", "payload" => payload}, acc) do
    Map.put(acc, payload["id"], payload)
  end

  defp fold_worker_event(%{"payload" => %{"id" => worker_id} = payload}, acc)
       when is_binary(worker_id) do
    Map.update(acc, worker_id, payload, fn worker ->
      worker
      |> Indexer.Agents.Registry.deep_merge(Map.drop(payload, ["id"]))
      |> Map.put("id", worker_id)
    end)
  end

  defp fold_worker_event(_event, acc), do: acc

  defp current_state({:ok, worker}), do: worker["state"]
  defp current_state({:error, :not_found}), do: nil

  defp append_worker_event!(project_root, type, worker_id, payload, opts) do
    event =
      Event.new(@stream, type, worker_id, payload,
        actor: Keyword.get(opts, :actor, %{"type" => "worker-supervisor", "id" => "indexer"}),
        causation_id: Keyword.get(opts, :causation_id),
        correlation_id: Keyword.get(opts, :correlation_id, payload["work_item_id"] || worker_id)
      )

    Jsonl.append_event!(project_root, event)
  end

  defp worker_dir(project_root, worker_id) do
    project_root
    |> Indexer.state_dir()
    |> Path.join("worktrees")
    |> Path.join(worker_id)
  end

  defp new_worker_id(work_item_id) do
    sanitized = String.replace(work_item_id, ~r/[^A-Za-z0-9_-]+/, "_")
    "worker-#{sanitized}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end
