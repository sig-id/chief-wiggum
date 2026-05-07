defmodule Indexer.Git.WorktreeTest do
  use ExUnit.Case, async: true

  alias Indexer.Git.Worktree

  test "prepares a worker worktree branch" do
    repo = git_repo!()
    commit_file!(repo, "base.txt", "base\n", "base")

    workspace = Path.join(repo, ".indexer/worktrees/worker-1/workspace")

    assert {:ok, result} =
             Worktree.prepare_worker(repo, %{
               "workspace_path" => workspace,
               "work_branch" => "indexer/work/TASK-001/worker-1",
               "target_ref" => "main"
             })

    assert result["status"] == "created"
    assert File.exists?(Path.join(workspace, "base.txt"))
    assert git!(workspace, ["branch", "--show-current"]) == "indexer/work/TASK-001/worker-1"

    assert {:ok, reused} =
             Worktree.prepare_worker(repo, %{
               "workspace_path" => workspace,
               "work_branch" => "indexer/work/TASK-001/worker-1",
               "target_ref" => "main"
             })

    assert reused["status"] == "exists"
  end

  defp git_repo! do
    path =
      Path.join(System.tmp_dir!(), "indexer-worktree-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "indexer@example.test"])
    git!(path, ["config", "user.name", "Indexer Test"])
    path
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
