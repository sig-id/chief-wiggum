defmodule Indexer.Effects.GitMergeEffectTest do
  use ExUnit.Case, async: true

  alias Indexer.Effects.{Effect, Executor, Outbox}

  test "merge effect updates change set, worker, and work item state" do
    repo = git_repo!()
    commit_file!(repo, "base.txt", "base\n", "base")
    branch!(repo, "feature")
    commit_file!(repo, "feature.txt", "feature\n", "feature")
    checkout!(repo, "main")

    Indexer.WorkItems.create!(repo, %{id: "TASK-001", title: "Merge me"})
    worker = Indexer.Workers.spawn!(repo, %{id: "worker-1", work_item_id: "TASK-001"})
    Indexer.Workers.transition!(repo, worker["id"], "merge.start")

    Indexer.ChangeSets.create!(repo, %{
      id: "cs-1",
      work_item_id: "TASK-001",
      worker_id: worker["id"],
      target_ref: "main",
      work_branch: "feature",
      affected_files: ["feature.txt"],
      status: "ready"
    })

    effect = Effect.new("git.merge_change_set", "change_set", "cs-1", %{})
    Outbox.record_pending!(repo, effect)

    assert {:ok, result} = Executor.drain(repo)
    assert result["completed"] == 1

    assert {:ok, change_set} = Indexer.ChangeSets.get(repo, "cs-1")
    assert change_set["status"] == "merged"
    assert is_binary(change_set["merge_sha"])

    assert {:ok, worker} = Indexer.Workers.get(repo, "worker-1")
    assert worker["state"] == "merged"

    assert {:ok, item} = Indexer.WorkItems.get(repo, "TASK-001")
    assert item["status"] == "merged"
  end

  defp git_repo! do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-git-effect-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "indexer@example.test"])
    git!(path, ["config", "user.name", "Indexer Test"])
    path
  end

  defp branch!(repo, branch), do: git!(repo, ["checkout", "-b", branch])
  defp checkout!(repo, branch), do: git!(repo, ["checkout", branch])

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
