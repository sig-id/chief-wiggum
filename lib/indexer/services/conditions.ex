defmodule Indexer.Services.Conditions do
  @moduledoc """
  Deterministic service condition checks.
  """

  @doc """
  Evaluates all configured conditions.
  """
  @spec met?(map() | nil, map()) :: boolean()
  def met?(nil, _context), do: true
  def met?(condition, _context) when condition == %{}, do: true

  def met?(condition, context) when is_map(condition) and is_map(context) do
    condition = Indexer.State.Json.normalize(condition)

    Enum.all?(condition, fn
      {"file_exists", pattern} -> glob(pattern, context) != []
      {"file_not_exists", pattern} -> glob(pattern, context) == []
      {"env_set", name} -> env_value(name, context) not in [nil, ""]
      {"env_equals", values} -> env_equals?(values, context)
      {"env_not_equals", values} -> env_not_equals?(values, context)
      {"service_mode", mode} -> Map.get(context, "run_mode", "default") == mode
      {"command", command} -> command_success?(command, context)
      {"ledger_has", _query} -> false
      {_unknown, _value} -> false
    end)
  end

  def met?(_condition, _context), do: false

  defp glob(pattern, context) when is_binary(pattern) do
    pattern
    |> render_path(context)
    |> Path.wildcard()
  end

  defp glob(_pattern, _context), do: []

  defp env_equals?(values, context) when is_map(values) do
    Enum.all?(values, fn {key, expected} -> env_value(key, context) == to_string(expected) end)
  end

  defp env_equals?(_values, _context), do: false

  defp env_not_equals?(values, context) when is_map(values) do
    Enum.all?(values, fn {key, expected} -> env_value(key, context) != to_string(expected) end)
  end

  defp env_not_equals?(_values, _context), do: false

  defp command_success?(command, context) do
    case normalize_command(command) do
      {:ok, executable, args} ->
        {_stdout, exit_code} =
          System.cmd(executable, args,
            cd: Map.get(context, "project_root", File.cwd!()),
            stderr_to_stdout: true
          )

        exit_code == 0

      :error ->
        false
    end
  rescue
    _exception -> false
  end

  defp normalize_command(command) when is_list(command) and command != [] do
    [executable | args] = command
    {:ok, executable, args}
  end

  defp normalize_command(_command), do: :error

  defp env_value(name, context) when is_binary(name) do
    context
    |> Map.get("env", %{})
    |> Map.get(name, System.get_env(name))
  end

  defp env_value(_name, _context), do: nil

  defp render_path(path, context) do
    project_root = Map.get(context, "project_root", File.cwd!())

    path =
      path
      |> String.replace("{{project_dir}}", project_root)
      |> String.replace("{{project_root}}", project_root)
      |> String.replace("{{indexer_dir}}", Indexer.state_dir(project_root))

    if Path.type(path) == :absolute, do: path, else: Path.join(project_root, path)
  end
end
