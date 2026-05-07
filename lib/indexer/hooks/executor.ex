defmodule Indexer.Hooks.Executor do
  @moduledoc """
  Executes deterministic hooks.

  Supported hook kinds:

  * `module` - trusted Elixir module implementing `run/1`
  * `executable` - external command using JSON stdin/stdout
  * `shell` - alias for `executable`
  """

  @type hook :: String.t() | map()
  @type result :: {:ok, map()} | {:error, map()}

  @doc """
  Runs a hook with the standard JSON-safe envelope.
  """
  @spec run(hook(), map()) :: result()
  def run(hook, envelope) when is_map(envelope) do
    hook
    |> normalize_hook()
    |> do_run(Indexer.State.Json.normalize(envelope))
    |> normalize_result()
  end

  defp normalize_hook(hook_name) when is_binary(hook_name) do
    %{"kind" => "module", "module" => hook_name}
  end

  defp normalize_hook(%{} = hook), do: Indexer.State.Json.normalize(hook)

  defp do_run(%{"kind" => "module", "module" => module_name}, envelope)
       when is_binary(module_name) do
    with {:ok, module} <- safe_module(module_name),
         true <-
           function_exported?(module, :run, 1) ||
             {:error, "module #{module_name} does not export run/1"} do
      module.run(envelope)
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp do_run(%{"kind" => kind, "command" => command} = hook, envelope)
       when kind in ["executable", "shell"] do
    run_executable(command, envelope, hook)
  end

  defp do_run(hook, _envelope), do: {:error, "unsupported hook #{inspect(hook)}"}

  defp run_executable(command, envelope, hook) when is_list(command) and command != [] do
    [executable | args] = command
    input = JSON.encode!(envelope)
    timeout = Map.get(hook, "timeout_ms", 30_000)

    case run_command_with_stdin(executable, args, input, timeout) do
      {:ok, stdout, 0} ->
        decode_hook_stdout(stdout)

      {:ok, stdout, exit_code} ->
        {:error,
         %{
           "status" => "hard_fail",
           "exit_code" => exit_code,
           "diagnostics" => [String.trim(stdout)]
         }}

      {:error, :timeout} ->
        {:error,
         %{"status" => "hard_fail", "diagnostics" => ["hook timed out after #{timeout}ms"]}}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp run_executable(command, _envelope, _hook) do
    {:error, "hook command must be a non-empty argv array, got #{inspect(command)}"}
  end

  defp decode_hook_stdout(stdout) do
    case JSON.decode(stdout) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, "hook stdout was not valid JSON: #{inspect(error)}"}
    end
  end

  defp run_command_with_stdin(executable, args, input, timeout) do
    task =
      Task.async(fn ->
        System.cmd(
          "sh",
          [
            "-c",
            "printf '%s' \"$INDEXER_HOOK_INPUT\" | \"$@\"",
            "indexer-hook",
            executable | args
          ],
          env: [{"INDEXER_HOOK_INPUT", input}],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, exit_code}} -> {:ok, stdout, exit_code}
      nil -> {:error, :timeout}
    end
  end

  defp normalize_result({:ok, %{} = result}), do: {:ok, normalize_hook_output(result)}
  defp normalize_result(%{} = result), do: {:ok, normalize_hook_output(result)}

  defp normalize_result({:error, %{} = error}) do
    {:error, normalize_hook_output(Map.put_new(error, "status", "hard_fail"))}
  end

  defp normalize_result({:error, reason}) do
    {:error, %{"status" => "hard_fail", "diagnostics" => [to_string(reason)]}}
  end

  defp normalize_result(other),
    do: {:error, %{"status" => "hard_fail", "diagnostics" => [inspect(other)]}}

  defp normalize_hook_output(output) do
    output
    |> Indexer.State.Json.normalize()
    |> Map.put_new("status", "ok")
    |> Map.put_new("context", %{})
    |> Map.put_new("artifacts", [])
    |> Map.put_new("effects", [])
    |> Map.put_new("diagnostics", [])
  end

  defp safe_module(module_name) do
    module = Module.concat([module_name])

    case Code.ensure_loaded(module) do
      {:module, module} ->
        {:ok, module}

      {:error, reason} ->
        {:error, "module #{module_name} could not be loaded: #{inspect(reason)}"}
    end
  end
end
