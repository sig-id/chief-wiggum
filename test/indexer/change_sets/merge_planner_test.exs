defmodule Indexer.ChangeSets.MergePlannerTest do
  use ExUnit.Case, async: true

  alias Indexer.ChangeSets.MergePlanner

  test "selects a non-overlapping ready batch on one target ref" do
    changes = [
      cs("cs-1", "main", ["lib/a.ex"]),
      cs("cs-2", "main", ["lib/b.ex"]),
      cs("cs-3", "main", ["lib/a.ex"]),
      cs("cs-4", "release", ["lib/c.ex"])
    ]

    assert Enum.map(MergePlanner.select_batch(changes), & &1["id"]) == ["cs-1", "cs-2"]
  end

  test "reports conflict groups by affected file overlap" do
    changes = [
      cs("cs-1", "main", ["lib/a.ex"]),
      cs("cs-2", "main", ["lib/a.ex", "lib/b.ex"]),
      cs("cs-3", "main", ["lib/b.ex"])
    ]

    assert ["cs-1", "cs-2"] in MergePlanner.conflict_groups(changes)
    assert ["cs-2", "cs-3"] in MergePlanner.conflict_groups(changes)
  end

  defp cs(id, target_ref, files) do
    %{
      "id" => id,
      "status" => "ready",
      "target_ref" => target_ref,
      "base_sha" => "base",
      "affected_files" => files
    }
  end
end
