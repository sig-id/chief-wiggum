defmodule Indexer.Git.MergeExecutor do
  @moduledoc """
  Executes git-native change-set merges.
  """

  alias Indexer.Git.Repository

  @doc """
  Merges a change set into its target ref.

  Returns:

  - `{:ok, %{status: "merged", ...}}`
  - `{:ok, %{status: "already_merged", ...}}`
  - `{:error, %{reason: "merge_conflict", ...}}`
  - `{:error, %{reason: "...", ...}}`
  """
  @spec merge_change_set(Path.t(), map()) :: {:ok, map()} | {:error, map()}
  def merge_change_set(repo, change_set) when is_binary(repo) and is_map(change_set) do
    change_set = Indexer.State.Json.normalize(change_set)
    target_ref = Map.fetch!(change_set, "target_ref")
    work_branch = Map.fetch!(change_set, "work_branch")

    with :ok <- ensure_repo(repo),
         :ok <- ensure_clean(repo),
         {:ok, target_sha} <- Repository.rev_parse(repo, target_ref),
         {:ok, head_sha} <- Repository.rev_parse(repo, work_branch) do
      cond do
        Repository.ancestor?(repo, head_sha, target_ref) ->
          {:ok,
           %{
             "status" => "already_merged",
             "target_ref" => target_ref,
             "merge_sha" => target_sha,
             "head_sha" => head_sha
           }}

        true ->
          do_merge(repo, target_ref, work_branch, target_sha, head_sha)
      end
    end
  rescue
    exception ->
      {:error,
       %{
         "reason" => "merge_exception",
         "class" => inspect(exception.__struct__),
         "message" => Exception.message(exception)
       }}
  end

  defp do_merge(repo, target_ref, work_branch, target_sha, head_sha) do
    with {:ok, _checkout} <- Repository.checkout(repo, target_ref) do
      case Repository.merge_no_ff(repo, work_branch) do
        {:ok, output} ->
          {:ok, merge_sha} = Repository.rev_parse(repo, "HEAD")

          {:ok,
           %{
             "status" => "merged",
             "target_ref" => target_ref,
             "base_sha" => target_sha,
             "head_sha" => head_sha,
             "merge_sha" => merge_sha,
             "output" => output
           }}

        {:error, error} ->
          files = Repository.conflicted_files(repo)
          Repository.merge_abort(repo)

          if files == [] do
            {:error, Map.put(error, "reason", "merge_failed")}
          else
            {:error,
             %{
               "reason" => "merge_conflict",
               "target_ref" => target_ref,
               "base_sha" => target_sha,
               "head_sha" => head_sha,
               "files" => files,
               "git_error" => error
             }}
          end
      end
    end
  end

  defp ensure_repo(repo) do
    if Repository.repo?(repo), do: :ok, else: {:error, %{"reason" => "not_git_repository"}}
  end

  defp ensure_clean(repo) do
    if Repository.clean?(repo), do: :ok, else: {:error, %{"reason" => "dirty_worktree"}}
  end
end
