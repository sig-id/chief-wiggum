defmodule Indexer.Agents.Result do
  @moduledoc """
  Deterministic result extraction helpers for agent runtime text.
  """

  @standard_results ~w(PASS FAIL FIX SKIP UNKNOWN)

  @doc """
  Extracts the semantic gate result from runtime text.
  """
  @spec extract_gate_result(String.t(), map() | struct()) :: String.t()
  def extract_gate_result(text, definition) when is_binary(text) do
    result_tag = field(definition, :result_tag, "result")
    valid_results = field(definition, :valid_results, @standard_results)

    cond do
      tagged = extract_tag(text, result_tag) ->
        normalize_result(tagged, valid_results)

      json_result = extract_json_result(text) ->
        normalize_result(json_result, valid_results)

      exact = exact_result(text, valid_results) ->
        exact

      true ->
        "UNKNOWN"
    end
  end

  @doc """
  Extracts a report tag from runtime text when present.
  """
  @spec extract_report(String.t(), map() | struct()) :: String.t() | nil
  def extract_report(text, definition) when is_binary(text) do
    extract_tag(text, field(definition, :report_tag, "report"))
  end

  defp extract_tag(text, tag) when is_binary(tag) and tag != "" do
    pattern = ~r/<#{Regex.escape(tag)}>\s*(.*?)\s*<\/#{Regex.escape(tag)}>/si

    case Regex.run(pattern, text, capture: :all_but_first) do
      [value] -> String.trim(value)
      _ -> nil
    end
  end

  defp extract_tag(_text, _tag), do: nil

  defp extract_json_result(text) do
    with {:ok, %{} = decoded} <- JSON.decode(text) do
      decoded = Indexer.State.Json.normalize(decoded)

      get_in(decoded, ["outputs", "gate_result"]) ||
        Map.get(decoded, "gate_result") ||
        Map.get(decoded, "result")
    else
      _ -> nil
    end
  end

  defp exact_result(text, valid_results) do
    value = text |> String.trim() |> String.upcase()
    if value in valid_results, do: value
  end

  defp normalize_result(result, valid_results) when is_binary(result) do
    value = result |> String.trim() |> String.upcase()

    cond do
      value in valid_results -> value
      value in @standard_results -> value
      true -> "UNKNOWN"
    end
  end

  defp normalize_result(_result, _valid_results), do: "UNKNOWN"

  defp field(%_{} = struct, key, default), do: Map.get(struct, key, default)

  defp field(%{} = map, key, default),
    do: Map.get(map, Atom.to_string(key), Map.get(map, key, default))

  defp field(_other, _key, default), do: default
end
