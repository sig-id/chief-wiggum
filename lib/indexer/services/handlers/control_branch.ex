defmodule Indexer.Services.Handlers.ControlBranch do
  @moduledoc """
  Default git-native control branch service handlers.
  """

  def sync(envelope), do: export(envelope)
  def publish(envelope), do: export(envelope)

  defp export(envelope) do
    project_root = get_in(envelope, ["context", "project_root"])
    result = Indexer.ControlBranch.Exporter.export!(project_root)

    {:ok,
     %{
       "status" => "ok",
       "handler" => __MODULE__ |> Atom.to_string(),
       "service_id" => get_in(envelope, ["service", "id"]),
       "export" => result
     }}
  end
end
