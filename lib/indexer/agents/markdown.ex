defmodule Indexer.Agents.Markdown do
  @moduledoc """
  Parser and renderer for declarative markdown agents.

  This is intentionally a small, dependency-free parser for the subset of YAML
  used by built-in agent frontmatter. Full YAML support can be added later behind
  the same API if the config surface needs it.
  """

  alias Indexer.Agents.Definition

  defstruct [:definition, :system_prompt, :user_prompt, :continuation_prompt, frontmatter: %{}]

  @type t :: %__MODULE__{
          definition: Definition.t(),
          system_prompt: String.t(),
          user_prompt: String.t(),
          continuation_prompt: String.t() | nil,
          frontmatter: map()
        }

  @doc """
  Parses an agent markdown file.
  """
  @spec parse_file!(Path.t()) :: t()
  def parse_file!(path) when is_binary(path) do
    path
    |> File.read!()
    |> parse!()
  end

  @doc """
  Parses agent markdown content.
  """
  @spec parse!(String.t()) :: t()
  def parse!(content) when is_binary(content) do
    {frontmatter_text, body} = split_frontmatter!(content)
    frontmatter = parse_frontmatter(frontmatter_text)

    {:ok, definition} = Definition.from_map(frontmatter)

    %__MODULE__{
      definition: definition,
      frontmatter: frontmatter,
      system_prompt: required_section!(body, "INDEXER_SYSTEM_PROMPT"),
      user_prompt: required_section!(body, "INDEXER_USER_PROMPT"),
      continuation_prompt: optional_section(body, "INDEXER_CONTINUATION_PROMPT")
    }
  end

  @doc """
  Renders a named prompt section with context interpolation and conditionals.
  """
  @spec render(t(), :system | :user | :continuation, map()) :: String.t()
  def render(%__MODULE__{} = agent, section, context \\ %{}) do
    agent
    |> prompt(section)
    |> render_template(context)
  end

  @doc """
  Renders a template with Indexer conditional tags and `{{var}}` interpolation.
  """
  @spec render_template(String.t() | nil, map()) :: String.t()
  def render_template(nil, _context), do: ""

  def render_template(template, context) when is_binary(template) and is_map(context) do
    context = Indexer.State.Json.normalize(context)

    template
    |> interpolate(context)
    |> apply_conditionals(context)
    |> String.trim()
  end

  defp prompt(agent, :system), do: agent.system_prompt
  defp prompt(agent, :user), do: agent.user_prompt
  defp prompt(agent, :continuation), do: agent.continuation_prompt

  defp split_frontmatter!(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3, trim: false) do
      ["", frontmatter, body] -> {frontmatter, body}
      _ -> raise ArgumentError, "agent markdown must start with YAML frontmatter delimited by ---"
    end
  end

  defp parse_frontmatter(frontmatter_text) do
    frontmatter_text
    |> String.split("\n", trim: true)
    |> Enum.reject(&comment_or_blank?/1)
    |> Enum.reduce(%{}, &parse_frontmatter_line/2)
  end

  defp parse_frontmatter_line(line, acc) do
    case String.split(line, ":", parts: 2) do
      [key, value] ->
        Map.put(acc, String.trim(key), parse_value(String.trim(value)))

      _ ->
        acc
    end
  end

  defp parse_value(""), do: ""
  defp parse_value("true"), do: true
  defp parse_value("false"), do: false

  defp parse_value(value) do
    cond do
      Regex.match?(~r/^\d+$/, value) ->
        String.to_integer(value)

      String.starts_with?(value, "[") and String.ends_with?(value, "]") ->
        value
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.split(",", trim: true)
        |> Enum.map(&strip_quotes(String.trim(&1)))

      true ->
        strip_quotes(value)
    end
  end

  defp strip_quotes(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp comment_or_blank?(line) do
    line = String.trim(line)
    line == "" or String.starts_with?(line, "#")
  end

  defp required_section!(body, tag) do
    case optional_section(body, tag) do
      nil -> raise ArgumentError, "missing required prompt section #{tag}"
      section -> section
    end
  end

  defp optional_section(body, tag) do
    pattern = ~r/<#{tag}>\s*(.*?)\s*<\/#{tag}>/s

    case Regex.run(pattern, body, capture: :all_but_first) do
      [section] -> section
      _ -> nil
    end
  end

  defp interpolate(template, context) do
    Regex.replace(~r/\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}/, template, fn _match, path ->
      context
      |> get_path(path)
      |> case do
        nil -> ""
        value when is_binary(value) -> value
        value -> to_string(value)
      end
    end)
  end

  defp apply_conditionals(template, context) do
    template
    |> apply_boolean_conditional(
      "INDEXER_IF_ITERATION_ZERO",
      get_path(context, "iteration") in [0, "0"]
    )
    |> apply_boolean_conditional(
      "INDEXER_IF_ITERATION_NONZERO",
      nonzero_iteration?(get_path(context, "iteration"))
    )
    |> apply_boolean_conditional(
      "INDEXER_IF_SUPERVISOR",
      present?(get_path(context, "supervisor_feedback"))
    )
    |> apply_context_conditionals(context)
    |> apply_file_exists_conditionals()
  end

  defp apply_boolean_conditional(template, tag, keep?) do
    Regex.replace(~r/<#{tag}>\s*(.*?)\s*<\/#{tag}>/s, template, fn _match, content ->
      if keep?, do: content, else: ""
    end)
  end

  defp apply_context_conditionals(template, context) do
    Regex.replace(
      ~r/<INDEXER_IF_CONTEXT:([^>]+)>\s*(.*?)\s*<\/INDEXER_IF_CONTEXT>/s,
      template,
      fn _match, key, content ->
        if present?(get_path(context, String.trim(key))), do: content, else: ""
      end
    )
  end

  defp apply_file_exists_conditionals(template) do
    Regex.replace(
      ~r/<INDEXER_IF_FILE_EXISTS:([^>]+)>\s*(.*?)\s*<\/INDEXER_IF_FILE_EXISTS>/s,
      template,
      fn _match, path, content ->
        if File.exists?(String.trim(path)), do: content, else: ""
      end
    )
  end

  defp get_path(map, path) when is_map(map) and is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce_while(map, fn key, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) -> {:cont, Map.get(acc, key)}
        true -> {:halt, nil}
      end
    end)
  end

  defp get_path(_map, _path), do: nil

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?([]), do: false
  defp present?(_value), do: true

  defp nonzero_iteration?(value) when is_integer(value), do: value > 0

  defp nonzero_iteration?(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer > 0
      _ -> false
    end
  end

  defp nonzero_iteration?(_value), do: false
end
