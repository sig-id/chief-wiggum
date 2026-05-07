defmodule Indexer.ControlBranch.ExporterTest do
  use ExUnit.Case, async: true

  alias Indexer.ControlBranch.Exporter
  alias Indexer.State.Jsonl

  test "exports work item, change-set, and projection snapshots" do
    root = tmp_dir()

    Indexer.WorkItems.create!(root, %{id: "TASK-001", title: "Export me", body: "Body"})

    Indexer.ChangeSets.create!(root, %{
      id: "cs-1",
      work_item_id: "TASK-001",
      worker_id: "worker-1",
      work_branch: "indexer/work/TASK-001/worker-1",
      affected_files: ["lib/a.ex"]
    })

    output_dir = Path.join(root, "control-export")
    result = Exporter.export!(root, output_dir: output_dir)

    assert result["work_items"] == 1
    assert result["change_sets"] == 1

    assert File.exists?(Path.join(output_dir, "work_items/TASK-001.json"))
    assert File.read!(Path.join(output_dir, "work_items/TASK-001.md")) =~ "# TASK-001: Export me"
    assert File.exists?(Path.join(output_dir, "change_sets/cs-1/change_set.json"))
    assert File.exists?(Path.join(output_dir, "snapshots/work_items.current.json"))

    events = root |> Jsonl.ledger_path("control_sync") |> Jsonl.read!()
    assert [%{"type" => "control_sync.exported"}] = events
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-control-export-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
