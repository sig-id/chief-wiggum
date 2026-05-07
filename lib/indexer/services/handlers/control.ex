defmodule Indexer.Services.Handlers.Control do
  @moduledoc """
  Default control-record service handlers.

  These are intentionally conservative placeholders. They establish the
  allowlisted handler surface used by `config/services.json`; substantive control
  branch reconciliation can fill in the same functions without changing service
  scheduling.
  """

  def validate(envelope), do: ok(envelope)

  defp ok(envelope) do
    {:ok,
     %{
       "status" => "ok",
       "handler" => __MODULE__ |> Atom.to_string(),
       "service_id" => get_in(envelope, ["service", "id"])
     }}
  end
end
