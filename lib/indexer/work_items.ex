defmodule Indexer.WorkItems do
  @moduledoc """
  JSONL-backed work item lifecycle.

  Work items replace the v1 kanban marker as the authoritative scheduling input.
  Status changes are append-only records and may later be mirrored to the git
  control branch.
  """

  alias Indexer.State.{Event, Jsonl}
  alias Indexer.WorkItems.WorkItem

  @stream "work_items"
  @dependency_stream "dependencies"

  @doc """
  Creates a work item.
  """
  @spec create!(Path.t(), map(), keyword()) :: map()
  def create!(project_root, attrs, opts \\ []) when is_binary(project_root) and is_map(attrs) do
    {:ok, item} = WorkItem.normalize_create(attrs)

    append_work_item_event!(project_root, "work_item.created", item["id"], item, opts)

    Enum.each(item["dependencies"], fn dependency_id ->
      append_dependency_event!(
        project_root,
        "dependency.added",
        item["id"],
        %{"work_item_id" => item["id"], "depends_on" => dependency_id},
        opts
      )
    end)

    item
  end

  @doc """
  Updates the status of a work item.
  """
  @spec update_status!(Path.t(), String.t(), String.t(), keyword()) :: map()
  def update_status!(project_root, work_item_id, status, opts \\ [])
      when is_binary(project_root) and is_binary(work_item_id) and is_binary(status) do
    unless WorkItem.valid_status?(status),
      do: raise(ArgumentError, "invalid work item status #{inspect(status)}")

    payload = %{
      "id" => work_item_id,
      "status" => status,
      "reason" => Keyword.get(opts, :reason),
      "changed_at" => timestamp()
    }

    append_work_item_event!(project_root, "work_item.status_changed", work_item_id, payload, opts)
  end

  @doc """
  Patches mutable work item fields.
  """
  @spec update!(Path.t(), String.t(), map(), keyword()) :: map()
  def update!(project_root, work_item_id, attrs, opts \\ [])
      when is_binary(project_root) and is_binary(work_item_id) and is_map(attrs) do
    payload =
      attrs
      |> Indexer.State.Json.normalize()
      |> Map.put("id", work_item_id)
      |> Map.put("updated_at", timestamp())

    append_work_item_event!(project_root, "work_item.updated", work_item_id, payload, opts)
  end

  @doc """
  Adds a dependency edge.
  """
  @spec add_dependency!(Path.t(), String.t(), String.t(), keyword()) :: map()
  def add_dependency!(project_root, work_item_id, dependency_id, opts \\ [])
      when is_binary(project_root) and is_binary(work_item_id) and is_binary(dependency_id) do
    append_dependency_event!(
      project_root,
      "dependency.added",
      work_item_id,
      %{"work_item_id" => work_item_id, "depends_on" => dependency_id},
      opts
    )
  end

  @doc """
  Folds work item and dependency ledgers into current work item state.
  """
  @spec current(Path.t()) :: map()
  def current(project_root) when is_binary(project_root) do
    items =
      project_root
      |> Jsonl.ledger_path(@stream)
      |> Jsonl.read!()
      |> Enum.reduce(%{}, &fold_work_item_event/2)

    dependencies =
      project_root
      |> Jsonl.ledger_path(@dependency_stream)
      |> Jsonl.read!()
      |> Enum.reduce(%{}, &fold_dependency_event/2)

    Map.new(items, fn {id, item} ->
      {id,
       Map.put(item, "dependencies", Map.get(dependencies, id, Map.get(item, "dependencies", [])))}
    end)
  end

  @doc """
  Returns a single work item projection.
  """
  @spec get(Path.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(project_root, work_item_id) when is_binary(project_root) and is_binary(work_item_id) do
    case Map.fetch(current(project_root), work_item_id) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Returns pending work items whose dependencies are all merged.
  """
  @spec ready(Path.t()) :: [map()]
  def ready(project_root) when is_binary(project_root) do
    items = current(project_root)

    items
    |> Map.values()
    |> Enum.filter(&(&1["status"] == "pending"))
    |> Enum.filter(&dependencies_satisfied?(&1, items))
    |> Enum.sort_by(&{-Map.get(&1, "priority", 0), &1["id"]})
  end

  @doc """
  Returns true if a work item satisfies dependency edges.
  """
  @spec dependency_satisfied?(map() | nil) :: boolean()
  def dependency_satisfied?(%{"status" => "merged"}), do: true
  def dependency_satisfied?(_item), do: false

  defp fold_work_item_event(%{"type" => "work_item.created", "payload" => payload}, acc) do
    Map.put(acc, payload["id"], payload)
  end

  defp fold_work_item_event(%{"type" => "work_item.updated", "payload" => payload}, acc) do
    id = payload["id"]

    Map.update(acc, id, payload, fn item ->
      item
      |> Indexer.Agents.Registry.deep_merge(Map.drop(payload, ["id"]))
      |> Map.put("id", id)
    end)
  end

  defp fold_work_item_event(%{"type" => "work_item.status_changed", "payload" => payload}, acc) do
    id = payload["id"]

    Map.update(
      acc,
      id,
      %{"id" => id, "status" => payload["status"]},
      &Map.put(&1, "status", payload["status"])
    )
  end

  defp fold_work_item_event(_event, acc), do: acc

  defp fold_dependency_event(%{"type" => "dependency.added", "payload" => payload}, acc) do
    work_item_id = payload["work_item_id"]
    dependency_id = payload["depends_on"]

    Map.update(acc, work_item_id, [dependency_id], fn dependencies ->
      Enum.uniq(dependencies ++ [dependency_id])
    end)
  end

  defp fold_dependency_event(%{"type" => "dependency.removed", "payload" => payload}, acc) do
    work_item_id = payload["work_item_id"]
    dependency_id = payload["depends_on"]

    Map.update(acc, work_item_id, [], &Enum.reject(&1, fn id -> id == dependency_id end))
  end

  defp fold_dependency_event(_event, acc), do: acc

  defp dependencies_satisfied?(item, items) do
    item
    |> Map.get("dependencies", [])
    |> Enum.all?(&(items |> Map.get(&1) |> dependency_satisfied?()))
  end

  defp append_work_item_event!(project_root, type, work_item_id, payload, opts) do
    event =
      Event.new(@stream, type, work_item_id, payload,
        actor: Keyword.get(opts, :actor, %{"type" => "operator", "id" => "indexer"}),
        causation_id: Keyword.get(opts, :causation_id),
        correlation_id: Keyword.get(opts, :correlation_id, work_item_id)
      )

    Jsonl.append_event!(project_root, event)
  end

  defp append_dependency_event!(project_root, type, work_item_id, payload, opts) do
    event =
      Event.new(@dependency_stream, type, work_item_id, payload,
        actor: Keyword.get(opts, :actor, %{"type" => "operator", "id" => "indexer"}),
        causation_id: Keyword.get(opts, :causation_id),
        correlation_id: Keyword.get(opts, :correlation_id, work_item_id)
      )

    Jsonl.append_event!(project_root, event)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end
