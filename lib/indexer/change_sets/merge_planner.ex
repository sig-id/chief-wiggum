defmodule Indexer.ChangeSets.MergePlanner do
  @moduledoc """
  Deterministic merge batch planner.

  The full merge optimizer can grow into the v1 maximum-independent-set strategy.
  This module starts with a conservative greedy independent batch: never select
  two change sets that target different refs in the same batch or touch the same
  affected file.
  """

  @doc """
  Selects a non-conflicting batch from ready change sets.
  """
  @spec select_batch([map()], keyword()) :: [map()]
  def select_batch(change_sets, opts \\ []) when is_list(change_sets) do
    max_batch = Keyword.get(opts, :max_batch, length(change_sets))

    change_sets
    |> Enum.filter(&(&1["status"] == "ready"))
    |> Enum.sort_by(&sort_key/1)
    |> Enum.reduce({[], MapSet.new(), nil}, fn change_set,
                                               {selected, touched_files, target_ref} ->
      cond do
        length(selected) >= max_batch ->
          {selected, touched_files, target_ref}

        target_ref && change_set["target_ref"] != target_ref ->
          {selected, touched_files, target_ref}

        MapSet.disjoint?(MapSet.new(Map.get(change_set, "affected_files", [])), touched_files) ->
          files = MapSet.new(Map.get(change_set, "affected_files", []))

          {selected ++ [change_set], MapSet.union(touched_files, files),
           target_ref || change_set["target_ref"]}

        true ->
          {selected, touched_files, target_ref}
      end
    end)
    |> elem(0)
  end

  @doc """
  Groups change sets by file overlap.
  """
  @spec conflict_groups([map()]) :: [[String.t()]]
  def conflict_groups(change_sets) when is_list(change_sets) do
    ids_by_file =
      change_sets
      |> Enum.flat_map(fn change_set ->
        Enum.map(Map.get(change_set, "affected_files", []), &{&1, change_set["id"]})
      end)
      |> Enum.group_by(fn {file, _id} -> file end, fn {_file, id} -> id end)

    ids_by_file
    |> Map.values()
    |> Enum.filter(&(length(Enum.uniq(&1)) > 1))
    |> Enum.map(&Enum.uniq/1)
  end

  defp sort_key(change_set) do
    {
      Map.get(change_set, "target_ref", "HEAD"),
      Map.get(change_set, "base_sha", ""),
      Map.get(change_set, "id", "")
    }
  end
end
