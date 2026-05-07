defmodule Indexer.WorkItems.WorkItem do
  @moduledoc """
  Work item data helpers.
  """

  @statuses MapSet.new([
              "pending",
              "in_progress",
              "pending_review",
              "merged",
              "failed",
              "not_planned"
            ])

  @doc """
  Returns true when a status is valid.
  """
  @spec valid_status?(String.t()) :: boolean()
  def valid_status?(status) when is_binary(status), do: MapSet.member?(@statuses, status)
  def valid_status?(_status), do: false

  @doc """
  Normalizes creation attributes.
  """
  @spec normalize_create(map()) :: {:ok, map()} | {:error, term()}
  def normalize_create(attrs) when is_map(attrs) do
    attrs = Indexer.State.Json.normalize(attrs)

    item =
      %{
        "id" => Map.get(attrs, "id") || new_id(),
        "title" => Map.get(attrs, "title"),
        "body" => Map.get(attrs, "body", ""),
        "status" => Map.get(attrs, "status", "pending"),
        "priority" => Map.get(attrs, "priority", 0),
        "target_ref" => Map.get(attrs, "target_ref", "HEAD"),
        "dependencies" => Map.get(attrs, "dependencies", []),
        "metadata" => Map.get(attrs, "metadata", %{})
      }
      |> Indexer.State.Json.normalize()

    with :ok <- validate_id(item["id"]),
         :ok <- validate_title(item["title"]),
         :ok <- validate_status(item["status"]),
         :ok <- validate_dependencies(item["dependencies"]) do
      {:ok, item}
    end
  end

  def normalize_create(_attrs), do: {:error, :invalid_work_item}

  defp validate_id(id) when is_binary(id) and id != "", do: :ok
  defp validate_id(_id), do: {:error, :invalid_work_item_id}

  defp validate_title(title) when is_binary(title) and title != "", do: :ok
  defp validate_title(_title), do: {:error, :invalid_work_item_title}

  defp validate_status(status) do
    if valid_status?(status), do: :ok, else: {:error, {:invalid_work_item_status, status}}
  end

  defp validate_dependencies(dependencies) when is_list(dependencies) do
    if Enum.all?(dependencies, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_dependencies}
  end

  defp validate_dependencies(_dependencies), do: {:error, :invalid_dependencies}

  defp new_id do
    "WI-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
