defmodule LiveChess.Engines.Engine do
  @moduledoc """
  Behaviour contract for remote chess engines consumed by the application.

  An engine module is responsible for answering best-move queries for the
  current board and providing deeper analysis when available.
  """

  @type move :: %{
          from: String.t(),
          to: String.t(),
          promotion: String.t(),
          promotion_piece: String.t() | nil,
          uci: String.t() | nil,
          engine: atom() | nil
        }

  @type pv_line :: %{
          moves: [String.t()],
          cp: integer() | nil,
          normalized_cp: integer() | nil,
          mate: integer() | nil,
          normalized_mate: integer() | nil,
          depth: integer() | nil,
          multipv: integer() | nil
        }

  @type evaluation :: %{
          fen: String.t(),
          score_cp: integer(),
          normalized_cp: integer() | nil,
          mate: integer() | nil,
          normalized_mate: integer() | nil,
          depth: integer() | nil,
          knodes: integer() | nil,
          best_move: move() | nil,
          lines: [pv_line()],
          raw: map() | nil,
          source: atom(),
          engine_name: String.t() | nil,
          win_chance: float() | nil
        }

  @callback source() :: atom()
  @callback enabled?() :: boolean()
  @callback evaluate(String.t(), keyword()) :: {:ok, evaluation()} | {:error, term()}
  @callback best_move(String.t(), keyword()) :: {:ok, move()} | {:error, term()}
end
