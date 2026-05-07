defmodule Indexer.Runtime.Adapters.Executable do
  @moduledoc """
  Generic process-per-invocation runtime adapter.

  The adapter is intentionally backend-neutral. It can front a local Codex,
  Claude, OpenCode, Pi, Hermes, PlotCode, ClockCode, or custom executable as long
  as the command is provided in runtime config. The command receives:

  * `INDEXER_INVOCATION_JSON` - normalized invocation JSON
  * `INDEXER_INVOCATION_FILE` - path to the same JSON on disk

  Structured stdout may be a JSON object with `text`, `session_id`, `turn_id`,
  `events`, and `status`. Plain text stdout is accepted and left for
  deterministic result extraction.
  """

  @behaviour Indexer.Runtime.Adapter

  alias Indexer.Runtime.{Invocation, Session}

  @impl true
  def init(config), do: {:ok, Indexer.State.Json.normalize(config)}

  @impl true
  def validate_config(config) do
    config = Indexer.State.Json.normalize(config)

    case Map.get(config, "command") do
      command when is_list(command) and command != [] ->
        :ok

      _ ->
        {:error, :missing_runtime_command}
    end
  end

  @impl true
  def capabilities(config) do
    config = Indexer.State.Json.normalize(config)

    %{
      "sessions" => Map.get(config, "supports_sessions", false),
      "named_sessions" => Map.get(config, "supports_named_sessions", false),
      "structured_stream" => Map.get(config, "structured_stream", false),
      "tool_events" => Map.get(config, "tool_events", false),
      "usage" => Map.get(config, "usage", false),
      "approvals" => Map.get(config, "approvals", false),
      "sandbox_workspace_write" => Map.get(config, "sandbox_workspace_write", false),
      "sandbox_readonly" => Map.get(config, "sandbox_readonly", false),
      "cancel_turn" => false
    }
  end

  @impl true
  def invoke(%Invocation{} = invocation) do
    config = Indexer.State.Json.normalize(invocation.runtime_config)
    [executable | args] = Map.fetch!(config, "command")
    timeout = timeout_ms(invocation, config)
    started_at = timestamp()

    with {:ok, invocation_file} <- write_invocation_file(invocation) do
      try do
        env = [
          {"INDEXER_INVOCATION_JSON", JSON.encode!(Indexer.State.Json.normalize(invocation))},
          {"INDEXER_INVOCATION_FILE", invocation_file},
          {"INDEXER_AGENT_RUN_ID", invocation.agent_run_id},
          {"INDEXER_AGENT_TYPE", invocation.agent_type},
          {"INDEXER_RUNTIME", invocation.runtime}
        ]

        case run_command(executable, args, invocation.workspace_path, env, timeout) do
          {:ok, stdout, 0} ->
            {:ok, build_session(invocation, stdout, started_at, config)}

          {:ok, stdout, exit_code} ->
            {:error, %{reason: :runtime_exit, exit_code: exit_code, output: stdout}}

          {:error, reason} ->
            {:error, reason}
        end
      after
        File.rm(invocation_file)
      end
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @impl true
  def build_exec_args(%Invocation{} = invocation) do
    config = Indexer.State.Json.normalize(invocation.runtime_config)

    case Map.get(config, "command") do
      command when is_list(command) and command != [] -> {:ok, command}
      _ -> {:error, :missing_runtime_command}
    end
  end

  @impl true
  def build_resume_args(_session, %Invocation{} = invocation), do: build_exec_args(invocation)

  @impl true
  def classify_error(:missing_runtime_command, _config), do: :permanent
  def classify_error(%{reason: :runtime_exit}, _config), do: :permanent
  def classify_error(:timeout, _config), do: :retryable
  def classify_error(_reason, _config), do: :retryable

  @impl true
  def extract_text(%Session{text: text}) when is_binary(text), do: {:ok, text}
  def extract_text(%{"text" => text}) when is_binary(text), do: {:ok, text}
  def extract_text(_artifact), do: {:error, :no_text}

  @impl true
  def extract_session_id(%Session{runtime_session_id: session_id}), do: {:ok, session_id}
  def extract_session_id(%{"session_id" => session_id}), do: {:ok, session_id}
  def extract_session_id(_artifact), do: {:ok, nil}

  @impl true
  def normalize_event(%{} = event), do: {:ok, Indexer.State.Json.normalize(event)}
  def normalize_event(_event), do: :ignore

  @impl true
  def supports_sessions?(config) do
    config
    |> Indexer.State.Json.normalize()
    |> Map.get("supports_sessions", false)
  end

  @impl true
  def usage_update(_usage, _config), do: :ok

  @impl true
  def rate_limit_check(_config), do: :ok

  @impl true
  def rate_limit_wait(_config), do: :ok

  @impl true
  def generate_session_id(_config) do
    "session_#{System.unique_integer([:positive, :monotonic])}"
  end

  @impl true
  def backend_name, do: "executable"

  @impl true
  def cancel_turn(_session, _config), do: {:error, :unsupported}

  defp write_invocation_file(invocation) do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-invocation-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    File.write(path, JSON.encode!(Indexer.State.Json.normalize(invocation)))
    |> case do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_command(executable, args, workspace_path, env, timeout) do
    task =
      Task.async(fn ->
        System.cmd(executable, args,
          cd: command_cwd(workspace_path),
          env: env,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, exit_code}} -> {:ok, stdout, exit_code}
      nil -> {:error, :timeout}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp command_cwd(path) when is_binary(path) do
    if File.dir?(path), do: path, else: File.cwd!()
  end

  defp command_cwd(_path), do: File.cwd!()

  defp build_session(invocation, stdout, started_at, config) do
    output = decode_output(stdout)
    text = output_text(output, stdout)
    now = timestamp()

    %Session{
      runtime: invocation.runtime,
      mode: invocation.mode,
      runtime_session_id:
        output["session_id"] || get_in(invocation.session, ["runtime_session_id"]),
      current_turn_id: output["turn_id"],
      os_pid: nil,
      status: output["status"] || "completed",
      started_at: started_at,
      last_event_at: now,
      text: text,
      raw_output: stdout,
      events: output["events"] || [],
      artifacts: output["artifacts"] || [],
      metadata:
        Map.drop(output, ["text", "session_id", "turn_id", "status", "events", "artifacts"]),
      supports_resume: supports_sessions?(config)
    }
  end

  defp decode_output(stdout) do
    case JSON.decode(stdout) do
      {:ok, %{} = decoded} -> Indexer.State.Json.normalize(decoded)
      _ -> %{}
    end
  end

  defp output_text(%{"text" => text}, _stdout) when is_binary(text), do: text
  defp output_text(%{"output" => text}, _stdout) when is_binary(text), do: text
  defp output_text(%{"message" => text}, _stdout) when is_binary(text), do: text
  defp output_text(_output, stdout), do: stdout

  defp timeout_ms(invocation, config) do
    seconds =
      get_in(invocation.policy, ["timeout_seconds"]) ||
        Map.get(config, "timeout_seconds") ||
        10_800

    seconds * 1_000
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end
