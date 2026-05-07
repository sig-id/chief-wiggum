defmodule Indexer.Git.Worktree do
  @moduledoc """
  Git worktree preparation for workers.
  """

  alias Indexer.Git.Repository

  @doc """
  Creates or reuses a worker git worktree.
  """
  @spec prepare_worker(Path.t(), map()) :: {:ok, map()} | {:error, map()}
  def prepare_worker(project_root, worker) when is_binary(project_root) and is_map(worker) do
    worker = Indexer.State.Json.normalize(worker)
    workspace_path = Map.fetch!(worker, "workspace_path")
    work_branch = Map.fetch!(worker, "work_branch")
    target_ref = Map.get(worker, "target_ref", "HEAD")

    cond do
      File.dir?(Path.join(workspace_path, ".git")) or gitfile?(workspace_path) ->
        {:ok,
         %{
           "status" => "exists",
           "workspace_path" => workspace_path,
           "work_branch" => work_branch,
           "target_ref" => target_ref
         }}

      File.exists?(workspace_path) and File.ls!(workspace_path) != [] ->
        {:error, %{"reason" => "workspace_path_not_empty", "workspace_path" => workspace_path}}

      true ->
        File.mkdir_p!(Path.dirname(workspace_path))

        case Repository.git(project_root, [
               "worktree",
               "add",
               "-B",
               work_branch,
               workspace_path,
               target_ref
             ]) do
          {:ok, output} ->
            {:ok,
             %{
               "status" => "created",
               "workspace_path" => workspace_path,
               "work_branch" => work_branch,
               "target_ref" => target_ref,
               "output" => output
             }}

          {:error, error} ->
            {:error, Map.put(error, "reason", "worktree_add_failed")}
        end
    end
  end

  defp gitfile?(workspace_path) do
    workspace_path
    |> Path.join(".git")
    |> File.regular?()
  end
end
