defmodule Indexer.Pipeline.Loader do
  @moduledoc """
  Loads and validates pipeline definitions.
  """

  alias Indexer.Pipeline.Schema

  @spec load_file!(Path.t()) :: map()
  def load_file!(path) when is_binary(path) do
    pipeline = Indexer.Config.read_json!(path)
    Schema.validate!(pipeline)
    Indexer.State.Json.normalize(pipeline)
  end
end
