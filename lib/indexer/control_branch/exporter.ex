defmodule Indexer.ControlBranch.Exporter do
  @moduledoc """
  Exports JSONL projections to a git-control-branch checkout directory.

  The exporter writes deterministic, human-reviewable files. It deliberately does
  not switch branches in the project checkout. A later git effect executor can
  commit this directory as `indexer/control` using a worktree.
  """

  alias Indexer.State.{Event, Jsonl}

  @doc """
  Writes a control snapshot under `.indexer/control` by default.
  """
  @spec export!(Path.t(), keyword()) :: map()
  def export!(project_root, opts \\ []) when is_binary(project_root) do
    output_dir =
      Keyword.get(opts, :output_dir, Path.join(Indexer.state_dir(project_root), "control"))

    File.mkdir_p!(output_dir)

    work_items = project_root |> Indexer.WorkItems.current() |> Map.values()
    change_sets = project_root |> Indexer.ChangeSets.current() |> Map.values()
    workers = project_root |> Indexer.Workers.current() |> Map.values()

    written =
      []
      |> write_work_items(output_dir, work_items)
      |> write_change_sets(output_dir, change_sets)
      |> write_snapshot(output_dir, "workers.current.json", workers)
      |> write_snapshot(output_dir, "change_sets.current.json", change_sets)
      |> write_snapshot(output_dir, "work_items.current.json", work_items)

    payload = %{
      "output_dir" => output_dir,
      "written" => written,
      "work_items" => length(work_items),
      "change_sets" => length(change_sets),
      "workers" => length(workers),
      "exported_at" => timestamp()
    }

    append_sync_event!(project_root, "control_sync.exported", payload, opts)
    payload
  end

  defp write_work_items(written, output_dir, work_items) do
    Enum.reduce(work_items, written, fn item, acc ->
      json_path = Path.join([output_dir, "work_items", "#{item["id"]}.json"])
      md_path = Path.join([output_dir, "work_items", "#{item["id"]}.md"])

      write_json!(json_path, item)
      write_text!(md_path, render_work_item(item))

      [relative(output_dir, md_path), relative(output_dir, json_path) | acc]
    end)
  end

  defp write_change_sets(written, output_dir, change_sets) do
    Enum.reduce(change_sets, written, fn change_set, acc ->
      json_path = Path.join([output_dir, "change_sets", change_set["id"], "change_set.json"])
      summary_path = Path.join([output_dir, "change_sets", change_set["id"], "summary.md"])

      write_json!(json_path, change_set)
      write_text!(summary_path, render_change_set(change_set))

      [relative(output_dir, summary_path), relative(output_dir, json_path) | acc]
    end)
  end

  defp write_snapshot(written, output_dir, filename, data) do
    path = Path.join([output_dir, "snapshots", filename])
    write_json!(path, data)
    [relative(output_dir, path) | written]
  end

  defp write_json!(path, data) do
    write_text!(path, JSON.encode!(Indexer.State.Json.normalize(data)))
  end

  defp write_text!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents <> "\n")
  end

  defp render_work_item(item) do
    """
    # #{item["id"]}: #{item["title"]}

    Status: #{item["status"]}
    Priority: #{Map.get(item, "priority", 0)}
    Target: #{Map.get(item, "target_ref", "HEAD")}
    Dependencies: #{Enum.join(Map.get(item, "dependencies", []), ", ")}

    #{Map.get(item, "body", "")}
    """
    |> String.trim()
  end

  defp render_change_set(change_set) do
    files =
      change_set
      |> Map.get("affected_files", [])
      |> Enum.map_join("\n", &"- #{&1}")

    """
    # #{change_set["id"]}

    Work item: #{change_set["work_item_id"]}
    Worker: #{change_set["worker_id"]}
    Status: #{change_set["status"]}
    Target: #{change_set["target_ref"]}
    Branch: #{change_set["work_branch"]}
    Head: #{change_set["head_sha"]}

    ## Affected Files

    #{files}
    """
    |> String.trim()
  end

  defp append_sync_event!(project_root, type, payload, opts) do
    event =
      Event.new("control_sync", type, "control:#{Indexer.control_branch()}", payload,
        actor: Keyword.get(opts, :actor, %{"type" => "control-branch", "id" => "exporter"}),
        correlation_id: Keyword.get(opts, :correlation_id)
      )

    Jsonl.append_event!(project_root, event)
  end

  defp relative(root, path), do: Path.relative_to(path, root)

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end
