defmodule Indexer.Effects.PrepareWorkerEffectTest do
  use ExUnit.Case, async: true

  alias Indexer.Effects.{Effect, Executor, Outbox}

  test "prepare worker effect creates worktree and updates worker projection" do
    repo = git_repo!()
    commit_file!(repo, "base.txt", "base\n", "base")

    worker =
      Indexer.Workers.spawn!(repo, %{
        id: "worker-1",
        work_item_id: "TASK-001",
        target_ref: "main"
      })

    effect = Effect.new("git.prepare_worker", "worker", worker["id"], %{})
    Outbox.record_pending!(repo, effect)

    assert {:ok, result} = Executor.drain(repo)
    assert result["completed"] == 1

    assert {:ok, projected} = Indexer.Workers.get(repo, worker["id"])
    assert projected["worktree_status"] == "created"
    assert File.exists?(Path.join(projected["workspace_path"], "base.txt"))
  end

  defp git_repo! do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-prepare-worker-effect-test-#{System.unique_integer([:positive])}"
      )

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
