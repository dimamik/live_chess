defmodule LiveChess.Engines.EvalCache do
  @moduledoc """
  ETS-based LRU cache for chess position evaluations.
  Caches the last 500 evaluations to reduce API calls.
  """

  use GenServer
  require Logger

  @table_name :chess_eval_cache
  @max_size 500

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a cached evaluation for a FEN position.
  Returns `{:ok, evaluation}` if found, `:miss` if not in cache.
  """
  def get(fen) when is_binary(fen) do
    case :ets.lookup(@table_name, fen) do
      [{^fen, evaluation, _timestamp}] ->
        # Update access timestamp
        GenServer.cast(__MODULE__, {:touch, fen})
        {:ok, evaluation}

      [] ->
        :miss
    end
  end

  @doc """
  Store an evaluation in the cache.
  """
  def put(fen, evaluation) when is_binary(fen) and is_map(evaluation) do
    GenServer.cast(__MODULE__, {:put, fen, evaluation})
  end

  @doc """
  Clear all entries from the cache.
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Get cache statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:set, :named_table, :public, read_concurrency: true])
    Logger.info("Chess evaluation cache initialized (max size: #{@max_size})")
    {:ok, %{table: table, hits: 0, misses: 0}}
  end

  @impl true
  def handle_cast({:touch, fen}, state) do
    case :ets.lookup(@table_name, fen) do
      [{^fen, evaluation, _old_timestamp}] ->
        :ets.insert(@table_name, {fen, evaluation, System.monotonic_time()})
        {:noreply, %{state | hits: state.hits + 1}}

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:put, fen, evaluation}, state) do
    current_size = :ets.info(@table_name, :size)

    if current_size >= @max_size do
      evict_oldest()
    end

    :ets.insert(@table_name, {fen, evaluation, System.monotonic_time()})
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table_name)
    {:reply, :ok, %{state | hits: 0, misses: 0}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    size = :ets.info(@table_name, :size)
    total_requests = state.hits + state.misses
    hit_rate = if total_requests > 0, do: state.hits / total_requests * 100, else: 0.0

    stats = %{
      size: size,
      max_size: @max_size,
      hits: state.hits,
      misses: state.misses,
      hit_rate: Float.round(hit_rate, 2)
    }

    {:reply, stats, state}
  end

  # Private Functions

  defp evict_oldest do
    # Find the entry with the oldest timestamp and remove it
    case :ets.foldl(
           fn {fen, _eval, timestamp}, acc ->
             case acc do
               nil -> {fen, timestamp}
               {_old_fen, old_timestamp} when timestamp < old_timestamp -> {fen, timestamp}
               _ -> acc
             end
           end,
           nil,
           @table_name
         ) do
      {oldest_fen, _timestamp} ->
        :ets.delete(@table_name, oldest_fen)

      nil ->
        :ok
    end
  end
end
