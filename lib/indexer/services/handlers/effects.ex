defmodule Indexer.Services.Handlers.Effects do
  @moduledoc """
  Default effect outbox service handlers.
  """

  def drain(envelope) do
    project_root = get_in(envelope, ["context", "project_root"])
    {:ok, drain_result} = Indexer.Effects.Executor.drain(project_root)

    {:ok,
     %{
       "status" => "ok",
       "handler" => __MODULE__ |> Atom.to_string(),
       "service_id" => get_in(envelope, ["service", "id"]),
       "drained" => drain_result["attempted"],
       "completed" => drain_result["completed"],
       "failed" => drain_result["failed"]
     }}
  end
end
