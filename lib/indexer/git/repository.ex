defmodule Indexer.Git.Repository do
  @moduledoc """
  Small git command boundary used by effect executors.

  This module is deliberately conservative. Mutating commands require a clean
  worktree and return structured errors instead of raising.
  """

  @doc """
  Runs a git command in a repository.
  """
  @spec git(Path.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, map()}
  def git(repo, args, opts \\ []) when is_binary(repo) and is_list(args) do
    {stdout, exit_code} =
      System.cmd("git", args,
        cd: repo,
        stderr_to_stdout: true,
        env: Keyword.get(opts, :env, [])
      )

    if exit_code == 0 do
      {:ok, String.trim(stdout)}
    else
      {:error,
       %{
         "reason" => "git_failed",
         "exit_code" => exit_code,
         "args" => args,
         "output" => stdout
       }}
    end
  rescue
    exception ->
      {:error,
       %{
         "reason" => "git_exception",
         "class" => inspect(exception.__struct__),
         "message" => Exception.message(exception),
         "args" => args
       }}
  end

  @spec repo?(Path.t()) :: boolean()
  def repo?(repo) do
    case git(repo, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, "true"} -> true
      _ -> false
    end
  end

  @spec clean?(Path.t()) :: boolean()
  def clean?(repo) do
    case git(repo, ["status", "--porcelain", "--untracked-files=no"]) do
      {:ok, ""} -> true
      {:ok, _dirty} -> false
      {:error, _error} -> false
    end
  end

  @spec rev_parse(Path.t(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def rev_parse(repo, ref) when is_binary(ref) do
    git(repo, ["rev-parse", "--verify", ref])
  end

  @spec ancestor?(Path.t(), String.t(), String.t()) :: boolean()
  def ancestor?(repo, ancestor, descendant) when is_binary(ancestor) and is_binary(descendant) do
    case git(repo, ["merge-base", "--is-ancestor", ancestor, descendant]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @spec checkout(Path.t(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def checkout(repo, ref) when is_binary(ref), do: git(repo, ["checkout", ref])

  @spec merge_no_ff(Path.t(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def merge_no_ff(repo, ref) when is_binary(ref) do
    git(repo, ["merge", "--no-ff", "--no-edit", ref])
  end

  @spec merge_abort(Path.t()) :: :ok
  def merge_abort(repo) do
    case git(repo, ["merge", "--abort"]) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  @spec conflicted_files(Path.t()) :: [String.t()]
  def conflicted_files(repo) do
    case git(repo, ["diff", "--name-only", "--diff-filter=U"]) do
      {:ok, ""} -> []
      {:ok, files} -> String.split(files, "\n", trim: true)
      {:error, _} -> []
    end
  end
end
