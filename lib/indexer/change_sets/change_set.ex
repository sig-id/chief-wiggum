defmodule Indexer.ChangeSets.ChangeSet do
  @moduledoc """
  Change-set validation helpers.
  """

  @statuses MapSet.new([
              "draft",
              "pending_review",
              "ready",
              "merging",
              "merge_conflict",
              "merged",
              "failed",
              "abandoned"
            ])

  @doc """
  Normalizes creation attributes.
  """
  @spec normalize_create(map()) :: {:ok, map()} | {:error, term()}
  def normalize_create(attrs) when is_map(attrs) do
    attrs = Indexer.State.Json.normalize(attrs)

    change_set =
      %{
        "id" => Map.get(attrs, "id") || new_id(Map.get(attrs, "work_item_id")),
        "work_item_id" => Map.get(attrs, "work_item_id"),
        "worker_id" => Map.get(attrs, "worker_id"),
        "target_ref" => Map.get(attrs, "target_ref", "HEAD"),
        "base_sha" => Map.get(attrs, "base_sha"),
        "work_branch" => Map.get(attrs, "work_branch"),
        "head_sha" => Map.get(attrs, "head_sha"),
        "affected_files" => Map.get(attrs, "affected_files", []),
        "status" => Map.get(attrs, "status", "draft"),
        "validation" => Map.get(attrs, "validation", %{}),
        "review" => Map.get(attrs, "review", %{}),
        "metadata" => Map.get(attrs, "metadata", %{})
      }

    with :ok <- require_string(change_set["id"], :invalid_change_set_id),
         :ok <- require_string(change_set["work_item_id"], :invalid_work_item_id),
         :ok <- require_string(change_set["worker_id"], :invalid_worker_id),
         :ok <- require_string(change_set["work_branch"], :invalid_work_branch),
         :ok <- validate_status(change_set["status"]),
         :ok <- validate_files(change_set["affected_files"]) do
      {:ok, change_set}
    end
  end

  def normalize_create(_attrs), do: {:error, :invalid_change_set}

  @doc """
  Returns true when a status is valid.
  """
  @spec valid_status?(String.t()) :: boolean()
  def valid_status?(status) when is_binary(status), do: MapSet.member?(@statuses, status)
  def valid_status?(_status), do: false

  defp require_string(value, _reason) when is_binary(value) and value != "", do: :ok
  defp require_string(_value, reason), do: {:error, reason}

  defp validate_status(status) do
    if valid_status?(status), do: :ok, else: {:error, {:invalid_change_set_status, status}}
  end

  defp validate_files(files) when is_list(files) do
    if Enum.all?(files, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_affected_files}
  end

  defp validate_files(_files), do: {:error, :invalid_affected_files}

  defp new_id(work_item_id) when is_binary(work_item_id) and work_item_id != "" do
    sanitized = String.replace(work_item_id, ~r/[^A-Za-z0-9_-]+/, "_")
    "cs-#{sanitized}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp new_id(_work_item_id) do
    "cs-#{System.unique_integer([:positive, :monotonic])}"
  end
end
