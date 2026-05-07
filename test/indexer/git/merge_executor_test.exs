defmodule Indexer.Git.MergeExecutorTest do
  use ExUnit.Case, async: true

  alias Indexer.Git.MergeExecutor

  test "merges a non-conflicting branch" do
    repo = git_repo!()
    commit_file!(repo, "base.txt", "base\n", "base")
    branch!(repo, "feature")
    commit_file!(repo, "feature.txt", "feature\n", "feature")
    checkout!(repo, "main")

    assert {:ok, result} =
             MergeExecutor.merge_change_set(repo, %{
               "target_ref" => "main",
               "work_branch" => "feature"
             })

    assert result["status"] == "merged"
    assert File.read!(Path.join(repo, "feature.txt")) == "feature\n"
  end

  test "detects already merged branch idempotently" do
    repo = git_repo!()
    commit_file!(repo, "base.txt", "base\n", "base")
    branch!(repo, "feature")
    commit_file!(repo, "feature.txt", "feature\n", "feature")
    checkout!(repo, "main")

    assert {:ok, _} =
             MergeExecutor.merge_change_set(repo, %{
               "target_ref" => "main",
               "work_branch" => "feature"
             })

    assert {:ok, result} =
             MergeExecutor.merge_change_set(repo, %{
               "target_ref" => "main",
               "work_branch" => "feature"
             })

    assert result["status"] == "already_merged"
  end

  test "detects conflicts and aborts the merge" do
    repo = git_repo!()
    commit_file!(repo, "same.txt", "base\n", "base")
    branch!(repo, "feature")
    commit_file!(repo, "same.txt", "feature\n", "feature")
    checkout!(repo, "main")
    commit_file!(repo, "same.txt", "main\n", "main")

    assert {:error, error} =
             MergeExecutor.merge_change_set(repo, %{
               "target_ref" => "main",
               "work_branch" => "feature"
             })

    assert error["reason"] == "merge_conflict"
    assert error["files"] == ["same.txt"]
    assert git!(repo, ["status", "--porcelain"]) == ""
  end

  defp git_repo! do
    path =
      Path.join(System.tmp_dir!(), "indexer-git-merge-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "indexer@example.test"])
    git!(path, ["config", "user.name", "Indexer Test"])
    path
  end

  defp branch!(repo, branch) do
    git!(repo, ["checkout", "-b", branch])
  end

  defp checkout!(repo, branch) do
    git!(repo, ["checkout", branch])
  end

  defp commit_file!(repo, path, contents, message) do
    File.write!(Path.join(repo, path), contents)
    git!(repo, ["add", path])
    git!(repo, ["commit", "-m", message])
  end

  defp git!(repo, args) do
    {stdout, exit_code} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert exit_code == 0, stdout
    String.trim(stdout)
  end
end
