defmodule LiveChess.Engines do
  @moduledoc """
  Facade for the configured remote chess engine.

  Engine modules implement `LiveChess.Engines.Engine` and are selected via the
  `:live_chess, :engine` application environment setting.
  """

  alias LiveChess.Engines.Engine

  @spec module() :: module()
  def module do
    Application.get_env(:live_chess, :engine, LiveChess.Engines.ChessApi)
  end

  @spec source() :: atom()
  def source do
    module().source()
  end

  @spec enabled?() :: boolean()
  def enabled? do
    module().enabled?()
  end

  @spec evaluate(String.t(), keyword()) :: {:ok, Engine.evaluation()} | {:error, term()}
  def evaluate(fen, opts \\ []) do
    module().evaluate(fen, opts)
  end

  @spec best_move(String.t(), keyword()) :: {:ok, Engine.move()} | {:error, term()}
  def best_move(fen, opts \\ []) do
    module().best_move(fen, opts)
  end
end
