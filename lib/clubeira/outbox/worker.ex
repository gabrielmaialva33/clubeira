defmodule Clubeira.Outbox.Worker do
  @moduledoc """
  Periodically delivers one outbox batch per polo.

  Every application node may run this worker. Row-level claims with
  `SKIP LOCKED` coordinate concurrent nodes without a leader election.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Clubeira.Outbox.Delivery
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl true
  def init(options) do
    state = %{
      initial_delay_ms: positive_integer!(options, :initial_delay_ms),
      interval_ms: positive_integer!(options, :interval_ms),
      delivery_options: delivery_options!(options)
    }

    schedule_publish(state.initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:publish_outbox, state) do
    publish_all_polos(state.delivery_options)
    schedule_publish(state.interval_ms)
    {:noreply, state}
  end

  defp publish_all_polos(delivery_options) do
    polo_ids =
      Repo.all(from route in PoloRoute, order_by: [asc: route.polo_id], select: route.polo_id)

    claimed_count =
      Enum.reduce(polo_ids, 0, fn polo_id, total ->
        total + publish_polo(polo_id, delivery_options)
      end)

    :telemetry.execute(
      [:clubeira, :outbox, :cycle],
      %{claimed_count: claimed_count, polo_count: length(polo_ids)},
      %{}
    )
  rescue
    error ->
      Logger.error("could not enumerate outbox polos: #{Exception.message(error)}")
  end

  defp publish_polo(polo_id, delivery_options) do
    scope = Scope.new!(polo_id, request_id: Ecto.UUID.generate(version: 7))

    case Delivery.run_once(scope, delivery_options) do
      {:ok, claimed_count} ->
        claimed_count

      {:error, reason} ->
        Logger.error(
          "outbox delivery transaction failed for polo=#{polo_id}: #{safe_reason(reason)}"
        )

        0
    end
  rescue
    error ->
      Logger.error("outbox delivery crashed for polo=#{polo_id}: #{Exception.message(error)}")
      0
  end

  defp delivery_options!(options) do
    [
      adapter: Keyword.fetch!(options, :adapter),
      adapter_options: Keyword.get(options, :adapter_options, []),
      worker_id: Keyword.get_lazy(options, :worker_id, &worker_id/0),
      batch_size: positive_integer!(options, :batch_size),
      lock_timeout_ms: positive_integer!(options, :lock_timeout_ms),
      max_attempts: positive_integer!(options, :max_attempts),
      retry_base_ms: positive_integer!(options, :retry_base_ms),
      retry_max_ms: positive_integer!(options, :retry_max_ms)
    ]
  end

  defp worker_id do
    "#{node()}:#{System.unique_integer([:positive, :monotonic])}"
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({kind, detail}) when is_atom(kind) and is_atom(detail), do: "#{kind}:#{detail}"
  defp safe_reason(_reason), do: "transaction_error"

  defp schedule_publish(delay_ms) do
    Process.send_after(self(), :publish_outbox, delay_ms)
  end

  defp positive_integer!(options, key) do
    case Keyword.fetch!(options, key) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end
end
