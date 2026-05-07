defmodule Indexer.Hooks.Hook do
  @moduledoc """
  Behaviour for trusted Elixir deterministic hooks.
  """

  @callback run(map()) :: {:ok, map()} | {:error, term()} | map()
end
