defmodule Indexer.Effects.Executor do
  @moduledoc """
  Idempotent effect outbox executor.

  This module executes deterministic state effects. Git effects are recorded with
  enough structure to be picked up by a stricter git executor later; the core
  state mutations already route through the outbox boundary.
  """

  alias Indexer.Effects.{Effect, Outbox}

  @doc """
  Drains pending effects once.
  """
  @spec drain(Path.t(), keyword()) :: {:ok, map()}
  def drain(project_root, opts \\ []) when is_binary(project_root) do
    effects = Outbox.pending(project_root)

    results =
      Enum.map(effects, fn effect_map ->
        effect = to_effect(effect_map)
        execute_one(project_root, effect, opts)
      end)

    {:ok,
     %{
       "attempted" => length(results),
       "completed" => Enum.count(results, &match?({:ok, _}, &1)),
       "failed" => Enum.count(results, &match?({:error, _}, &1)),
       "results" => Enum.map(results, &normalize_result/1)
     }}
  end

  @doc """
  Executes one effect and records completion/failure.
  """
  @spec execute_one(Path.t(), Effect.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def execute_one(project_root, %Effect{} = effect, opts \\ []) do
    runner = Keyword.get(opts, :runner, &dispatch/2)

    case runner.(project_root, effect) do
      {:ok, result} ->
        Outbox.mark_completed!(project_root, effect, result)
        {:ok, result}

      {:error, error} ->
        error = normalize_error(error)
        Outbox.mark_failed!(project_root, effect, error)
        {:error, error}
    end
  rescue
    exception ->
      error = %{
        "reason" => Exception.message(exception),
        "class" => inspect(exception.__struct__)
      }

      Outbox.mark_failed!(project_root, effect, error)
      {:error, error}
  end

  defp dispatch(project_root, %Effect{effect_type: "work_item.create", payload: payload}) do
    {:ok, %{"work_item" => Indexer.WorkItems.create!(project_root, payload)}}
  end

  defp dispatch(project_root, %Effect{
         effect_type: "work_item.status",
         scope_id: work_item_id,
         payload: payload
       }) do
    status = Map.fetch!(payload, "status")
    {:ok, %{"work_item" => Indexer.WorkItems.update_status!(project_root, work_item_id, status)}}
  end

  defp dispatch(project_root, %Effect{effect_type: "worker.spawn", payload: payload}) do
    {:ok, %{"worker" => Indexer.Workers.spawn!(project_root, payload)}}
  end

  defp dispatch(project_root, %Effect{effect_type: "git.prepare_worker", scope_id: worker_id}) do
    with {:ok, worker} <- Indexer.Workers.get(project_root, worker_id),
         {:ok, result} <- Indexer.Git.Worktree.prepare_worker(project_root, worker) do
      Indexer.Workers.update!(project_root, worker_id, %{
        "workspace_path" => result["workspace_path"],
        "work_branch" => result["work_branch"],
        "worktree_status" => result["status"]
      })

      {:ok, Map.put(result, "worker_id", worker_id)}
    end
  end

  defp dispatch(project_root, %Effect{effect_type: "change_set.create", payload: payload}) do
    {:ok, %{"change_set" => Indexer.ChangeSets.create!(project_root, payload)}}
  end

  defp dispatch(project_root, %Effect{
         effect_type: "git.merge_change_set",
         scope_id: change_set_id
       }) do
    with {:ok, change_set} <- Indexer.ChangeSets.get(project_root, change_set_id) do
      Indexer.ChangeSets.update_status!(project_root, change_set_id, "merging")

      case Indexer.Git.MergeExecutor.merge_change_set(project_root, change_set) do
        {:ok, %{"status" => "already_merged"} = result} ->
          Indexer.ChangeSets.mark_merged!(project_root, change_set_id, result["merge_sha"])

          maybe_transition_worker(
            project_root,
            change_set["worker_id"],
            "merge.already_merged",
            result
          )

          maybe_mark_work_item_merged(project_root, change_set["work_item_id"])
          {:ok, Map.put(result, "change_set_id", change_set_id)}

        {:ok, %{"status" => "merged"} = result} ->
          Indexer.ChangeSets.mark_merged!(project_root, change_set_id, result["merge_sha"])

          maybe_transition_worker(
            project_root,
            change_set["worker_id"],
            "merge.succeeded",
            result
          )

          maybe_mark_work_item_merged(project_root, change_set["work_item_id"])
          {:ok, Map.put(result, "change_set_id", change_set_id)}

        {:error, %{"reason" => "merge_conflict"} = error} ->
          Indexer.ChangeSets.mark_conflict!(project_root, change_set_id, %{
            "files" => error["files"]
          })

          maybe_transition_worker(project_root, change_set["worker_id"], "merge.conflict", error)
          {:error, Map.put(error, "change_set_id", change_set_id)}

        {:error, error} ->
          Indexer.ChangeSets.update_status!(project_root, change_set_id, "failed", %{
            "error" => error
          })

          maybe_transition_worker(project_root, change_set["worker_id"], "merge.hard_fail", error)
          {:error, Map.put(error, "change_set_id", change_set_id)}
      end
    end
  end

  defp dispatch(_project_root, %Effect{effect_type: effect_type}) do
    {:error, %{"reason" => "unsupported_effect", "effect_type" => effect_type}}
  end

  defp to_effect(effect_map) do
    %Effect{
      id: Map.fetch!(effect_map, "id"),
      batch_id: effect_map["batch_id"],
      effect_type: Map.fetch!(effect_map, "effect_type"),
      scope_type: Map.fetch!(effect_map, "scope_type"),
      scope_id: Map.fetch!(effect_map, "scope_id"),
      idempotency_key: Map.fetch!(effect_map, "idempotency_key"),
      payload: Map.get(effect_map, "payload", %{}),
      status: Map.get(effect_map, "status", "pending"),
      attempts: Map.get(effect_map, "attempts", 0)
    }
  end

  defp normalize_result({:ok, result}), do: %{"status" => "completed", "result" => result}
  defp normalize_result({:error, error}), do: %{"status" => "failed", "error" => error}

  defp normalize_error(error) when is_map(error), do: Indexer.State.Json.normalize(error)
  defp normalize_error(error), do: %{"reason" => inspect(error)}

  defp maybe_transition_worker(_project_root, nil, _event_type, _payload), do: :ok

  defp maybe_transition_worker(project_root, worker_id, event_type, payload) do
    Indexer.Workers.transition!(project_root, worker_id, event_type, payload)
    :ok
  rescue
    _exception -> :ok
  end

  defp maybe_mark_work_item_merged(_project_root, nil), do: :ok

  defp maybe_mark_work_item_merged(project_root, work_item_id) do
    Indexer.WorkItems.update_status!(project_root, work_item_id, "merged",
      reason: "change_set_merged"
    )

    :ok
  rescue
    _exception -> :ok
  end
end
