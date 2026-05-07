defmodule Indexer.ChangeSets do
  @moduledoc """
  JSONL-backed git-native change sets.

  Change sets are the v2 replacement for GitHub pull requests in core state. A
  hosted forge adapter may mirror them, but pipelines and services route through
  this ledger.
  """

  alias Indexer.ChangeSets.ChangeSet
  alias Indexer.State.{Event, Jsonl}

  @stream "change_sets"

  @doc """
  Creates a change set.
  """
  @spec create!(Path.t(), map(), keyword()) :: map()
  def create!(project_root, attrs, opts \\ []) when is_binary(project_root) and is_map(attrs) do
    {:ok, change_set} = ChangeSet.normalize_create(attrs)

    append_change_set_event!(
      project_root,
      "change_set.created",
      change_set["id"],
      change_set,
      opts
    )

    change_set
  end

  @doc """
  Updates mutable change-set fields.
  """
  @spec update!(Path.t(), String.t(), map(), keyword()) :: map()
  def update!(project_root, change_set_id, attrs, opts \\ [])
      when is_binary(project_root) and is_binary(change_set_id) and is_map(attrs) do
    payload =
      attrs
      |> Indexer.State.Json.normalize()
      |> Map.put("id", change_set_id)
      |> Map.put("updated_at", timestamp())

    append_change_set_event!(project_root, "change_set.updated", change_set_id, payload, opts)
    payload
  end

  @doc """
  Changes merge/review status.
  """
  @spec update_status!(Path.t(), String.t(), String.t(), map(), keyword()) :: map()
  def update_status!(project_root, change_set_id, status, details \\ %{}, opts \\ [])
      when is_binary(project_root) and is_binary(change_set_id) and is_binary(status) and
             is_map(details) do
    unless ChangeSet.valid_status?(status),
      do: raise(ArgumentError, "invalid change-set status #{inspect(status)}")

    payload =
      details
      |> Indexer.State.Json.normalize()
      |> Map.merge(%{"id" => change_set_id, "status" => status, "changed_at" => timestamp()})

    append_change_set_event!(
      project_root,
      "change_set.status_changed",
      change_set_id,
      payload,
      opts
    )

    payload
  end

  @doc """
  Marks a change set ready for merge consideration.
  """
  @spec mark_ready!(Path.t(), String.t(), keyword()) :: map()
  def mark_ready!(project_root, change_set_id, opts \\ []) do
    update_status!(project_root, change_set_id, "ready", %{}, opts)
  end

  @doc """
  Marks a change set merged.
  """
  @spec mark_merged!(Path.t(), String.t(), String.t(), keyword()) :: map()
  def mark_merged!(project_root, change_set_id, merge_sha, opts \\ []) do
    update_status!(project_root, change_set_id, "merged", %{"merge_sha" => merge_sha}, opts)
  end

  @doc """
  Marks a merge conflict.
  """
  @spec mark_conflict!(Path.t(), String.t(), map(), keyword()) :: map()
  def mark_conflict!(project_root, change_set_id, conflict, opts \\ []) when is_map(conflict) do
    update_status!(project_root, change_set_id, "merge_conflict", %{"conflict" => conflict}, opts)
  end

  @doc """
  Folds change-set events into current state.
  """
  @spec current(Path.t()) :: map()
  def current(project_root) when is_binary(project_root) do
    project_root
    |> Jsonl.ledger_path(@stream)
    |> Jsonl.read!()
    |> Enum.reduce(%{}, &fold_change_set_event/2)
  end

  @doc """
  Gets one change-set projection.
  """
  @spec get(Path.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(project_root, change_set_id)
      when is_binary(project_root) and is_binary(change_set_id) do
    case Map.fetch(current(project_root), change_set_id) do
      {:ok, change_set} -> {:ok, change_set}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Lists change sets ready for merge.
  """
  @spec ready_for_merge(Path.t()) :: [map()]
  def ready_for_merge(project_root) when is_binary(project_root) do
    project_root
    |> current()
    |> Map.values()
    |> Enum.filter(&(&1["status"] == "ready"))
    |> Enum.sort_by(&{&1["target_ref"], &1["id"]})
  end

  defp fold_change_set_event(%{"type" => "change_set.created", "payload" => payload}, acc) do
    Map.put(acc, payload["id"], payload)
  end

  defp fold_change_set_event(%{"type" => "change_set.updated", "payload" => payload}, acc) do
    id = payload["id"]

    Map.update(acc, id, payload, fn change_set ->
      change_set
      |> Indexer.Agents.Registry.deep_merge(Map.drop(payload, ["id"]))
      |> Map.put("id", id)
    end)
  end

  defp fold_change_set_event(%{"type" => "change_set.status_changed", "payload" => payload}, acc) do
    id = payload["id"]

    Map.update(acc, id, payload, fn change_set ->
      change_set
      |> Indexer.Agents.Registry.deep_merge(Map.drop(payload, ["id"]))
      |> Map.put("id", id)
    end)
  end

  defp fold_change_set_event(_event, acc), do: acc

  defp append_change_set_event!(project_root, type, change_set_id, payload, opts) do
    event =
      Event.new(@stream, type, change_set_id, payload,
        actor: Keyword.get(opts, :actor, %{"type" => "merge-manager", "id" => "indexer"}),
        causation_id: Keyword.get(opts, :causation_id),
        correlation_id:
          Keyword.get(opts, :correlation_id, Map.get(payload, "work_item_id", change_set_id))
      )

    Jsonl.append_event!(project_root, event)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end
