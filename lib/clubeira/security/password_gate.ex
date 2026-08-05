defmodule Clubeira.Security.PasswordGate do
  @moduledoc """
  Fail-fast concurrency gate around memory-hard password hashing and verification.

  Callers are monitored so a crashed request cannot leak a permit. Waiting
  requests are rejected instead of building an unbounded dirty-scheduler queue.
  """

  use GenServer

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @spec run(server(), (-> result)) :: result | {:error, :capacity_exhausted}
        when result: var
  def run(server \\ __MODULE__, operation) when is_function(operation, 0) do
    case GenServer.call(server, {:acquire, self()}) do
      {:ok, permit} ->
        try do
          operation.()
        after
          :ok = GenServer.call(server, {:release, permit})
        end

      :capacity_exhausted ->
        {:error, :capacity_exhausted}
    end
  end

  @impl true
  def init(options) do
    max_concurrency = Keyword.fetch!(options, :max_concurrency)

    if is_integer(max_concurrency) and max_concurrency > 0 do
      {:ok, %{max_concurrency: max_concurrency, holders: %{}}}
    else
      {:stop, {:invalid_max_concurrency, max_concurrency}}
    end
  end

  @impl true
  def handle_call({:acquire, caller}, _from, state) do
    if map_size(state.holders) < state.max_concurrency do
      permit = Process.monitor(caller)
      {:reply, {:ok, permit}, put_in(state.holders[permit], caller)}
    else
      {:reply, :capacity_exhausted, state}
    end
  end

  def handle_call({:release, permit}, _from, state) do
    case Map.pop(state.holders, permit) do
      {nil, _holders} ->
        {:reply, :ok, state}

      {_caller, holders} ->
        Process.demonitor(permit, [:flush])
        {:reply, :ok, %{state | holders: holders}}
    end
  end

  @impl true
  def handle_info({:DOWN, permit, :process, _caller, _reason}, state) do
    {:noreply, %{state | holders: Map.delete(state.holders, permit)}}
  end
end
