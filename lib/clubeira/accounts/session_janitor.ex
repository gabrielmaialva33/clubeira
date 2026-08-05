defmodule Clubeira.Accounts.SessionJanitor do
  @moduledoc """
  Periodically enforces retention for expired and revoked authentication sessions.

  Cleanup is idempotent, so multiple application nodes may run it safely.
  """

  use GenServer

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Accounts.PasswordRecovery

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(options) do
    state = %{
      initial_delay_ms: positive_integer!(options, :initial_delay_ms),
      interval_ms: positive_integer!(options, :interval_ms),
      retention_seconds: positive_integer!(options, :retention_seconds)
    }

    schedule_cleanup(state.initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:purge_stale_sessions, state) do
    purge(state.retention_seconds)
    schedule_cleanup(state.interval_ms)
    {:noreply, state}
  end

  defp purge(retention_seconds) do
    cutoff = DateTime.add(DateTime.utc_now(:microsecond), -retention_seconds, :second)
    deleted_session_count = Accounts.purge_stale_sessions(cutoff)
    deleted_reset_token_count = PasswordRecovery.purge_stale_tokens(cutoff)

    :telemetry.execute(
      [:clubeira, :accounts, :sessions_purged],
      %{count: deleted_session_count},
      %{}
    )

    :telemetry.execute(
      [:clubeira, :accounts, :password_reset_tokens_purged],
      %{count: deleted_reset_token_count},
      %{}
    )
  rescue
    error ->
      Logger.error(
        "could not purge stale sessions: #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  end

  defp schedule_cleanup(delay_ms) do
    Process.send_after(self(), :purge_stale_sessions, delay_ms)
  end

  defp positive_integer!(options, key) do
    case Keyword.fetch!(options, key) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end
end
