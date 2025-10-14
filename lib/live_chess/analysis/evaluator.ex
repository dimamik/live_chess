defmodule LiveChess.Analysis.Evaluator do
  @moduledoc """
  Lightweight chess evaluation used to power the advantage bar.

  The evaluator favours rapid, side-effect-free heuristics so that every board
  update can surface an approximate engine score without blocking gameplay.
  Material is still the backbone, but development, king safety, and attacking
  pressure all feed into the final centipawn estimate.
  """

  alias Chess.Game
  alias LiveChess.Engines
  alias MapSet

  require Logger

  @piece_values %{
    "p" => 100,
    "n" => 320,
    "b" => 330,
    "r" => 500,
    "q" => 900,
    "k" => 0
  }

  @score_cap 1500
  @check_bonus 350
  @development_reward 20

  @pawn_table List.flatten([
                [0, 0, 0, 0, 0, 0, 0, 0],
                [50, 50, 50, 50, 50, 50, 50, 50],
                [10, 10, 20, 30, 30, 20, 10, 10],
                [5, 5, 10, 25, 25, 10, 5, 5],
                [0, 0, 0, 20, 20, 0, 0, 0],
                [5, -5, -10, 0, 0, -10, -5, 5],
                [5, 10, 10, -20, -20, 10, 10, 5],
                [0, 0, 0, 0, 0, 0, 0, 0]
              ])

  @knight_table List.flatten([
                  [-50, -40, -30, -30, -30, -30, -40, -50],
                  [-40, -20, 0, 0, 0, 0, -20, -40],
                  [-30, 0, 10, 15, 15, 10, 0, -30],
                  [-30, 5, 15, 20, 20, 15, 5, -30],
                  [-30, 0, 15, 20, 20, 15, 0, -30],
                  [-30, 5, 10, 15, 15, 10, 5, -30],
                  [-40, -20, 0, 5, 5, 0, -20, -40],
                  [-50, -40, -30, -30, -30, -30, -40, -50]
                ])

  @bishop_table List.flatten([
                  [-20, -10, -10, -10, -10, -10, -10, -20],
                  [-10, 0, 0, 0, 0, 0, 0, -10],
                  [-10, 0, 5, 10, 10, 5, 0, -10],
                  [-10, 5, 5, 10, 10, 5, 5, -10],
                  [-10, 0, 10, 10, 10, 10, 0, -10],
                  [-10, 10, 10, 10, 10, 10, 10, -10],
                  [-10, 5, 0, 0, 0, 0, 5, -10],
                  [-20, -10, -10, -10, -10, -10, -10, -20]
                ])

  @rook_table List.flatten([
                [0, 0, 0, 5, 5, 0, 0, 0],
                [-5, 0, 0, 0, 0, 0, 0, -5],
                [-5, 0, 0, 0, 0, 0, 0, -5],
                [-5, 0, 0, 0, 0, 0, 0, -5],
                [-5, 0, 0, 0, 0, 0, 0, -5],
                [-5, 0, 0, 0, 0, 0, 0, -5],
                [5, 10, 10, 10, 10, 10, 10, 5],
                [0, 0, 0, 0, 0, 0, 0, 0]
              ])

  @queen_table List.flatten([
                 [-20, -10, -10, -5, -5, -10, -10, -20],
                 [-10, 0, 0, 0, 0, 0, 0, -10],
                 [-10, 0, 5, 5, 5, 5, 0, -10],
                 [-5, 0, 5, 5, 5, 5, 0, -5],
                 [0, 0, 5, 5, 5, 5, 0, -5],
                 [-10, 5, 5, 5, 5, 5, 0, -10],
                 [-10, 0, 5, 0, 0, 0, 0, -10],
                 [-20, -10, -10, -5, -5, -10, -10, -20]
               ])

  @king_table List.flatten([
                [-30, -40, -40, -50, -50, -40, -40, -30],
                [-30, -40, -40, -50, -50, -40, -40, -30],
                [-30, -40, -40, -50, -50, -40, -40, -30],
                [-30, -40, -40, -50, -50, -40, -40, -30],
                [-20, -30, -30, -40, -40, -30, -30, -20],
                [-10, -20, -20, -20, -20, -20, -20, -10],
                [20, 20, 0, 0, 0, 0, 20, 20],
                [20, 30, 10, 0, 0, 10, 30, 20]
              ])

  @piece_square_tables %{
    "p" => @pawn_table,
    "n" => @knight_table,
    "b" => @bishop_table,
    "r" => @rook_table,
    "q" => @queen_table,
    "k" => @king_table
  }

  @zero_table List.duplicate(0, 64)

  @white_minor_starts MapSet.new(["b1", "g1", "c1", "f1"])
  @black_minor_starts MapSet.new(["b8", "g8", "c8", "f8"])

  @type evaluation :: %{
          score_cp: integer(),
          display_score: String.t(),
          white_percentage: float(),
          advantage: :white | :black | :equal
        }

  @spec summary(%{game: Game.t(), status: atom()}, :white | :black | nil) :: evaluation()
  def summary(%{game: %Game{} = game, status: status} = state, winner) do
    case engine_summary(game, status, winner) do
      {:ok, evaluation} -> evaluation
      {:error, _reason} -> heuristic_summary(state, winner)
    end
  end

  def summary(state, winner), do: heuristic_summary(state, winner)

  defp engine_summary(%Game{} = game, status, winner) do
    case Engines.evaluate(game.current_fen) do
      {:ok, evaluation} ->
        {:ok, build_engine_summary(evaluation, status, winner)}

      {:error, :disabled} ->
        {:error, :disabled}

      {:error, reason} ->
        log_engine_error(reason)
        {:error, reason}
    end
  end

  defp engine_summary(_, _status, _winner), do: {:error, :invalid_state}

  defp build_engine_summary(evaluation, status, winner) do
    raw_score = Map.get(evaluation, :normalized_cp) || Map.get(evaluation, :score_cp, 0)
    score_cp = raw_score |> clamp_score()
    mate = Map.get(evaluation, :normalized_mate) || Map.get(evaluation, :mate)
    source = Map.get(evaluation, :source, Engines.source())
    engine_name = Map.get(evaluation, :engine_name, engine_label(source))

    advantage =
      cond do
        winner in [:white, :black] -> winner
        is_integer(mate) and mate != 0 -> if mate > 0, do: :white, else: :black
        score_cp > 40 -> :white
        score_cp < -40 -> :black
        true -> :equal
      end

    display_score =
      cond do
        winner == :white ->
          "+M"

        winner == :black ->
          "-M"

        is_integer(mate) and mate != 0 ->
          prefix = if mate > 0, do: "+M", else: "-M"
          prefix <> Integer.to_string(abs(mate))

        true ->
          format_score(score_cp)
      end

    white_percentage =
      cond do
        winner == :white -> 100.0
        winner == :black -> 0.0
        status in [:stalemate, :draw] -> 50.0
        is_integer(mate) and mate != 0 -> if mate > 0, do: 100.0, else: 0.0
        true -> clamp_to_percentage(score_cp)
      end

    base = %{
      score_cp: score_cp,
      display_score: display_score,
      white_percentage: Float.round(white_percentage, 2),
      advantage: advantage,
      source: source,
      engine: %{
        name: engine_name,
        depth: Map.get(evaluation, :depth),
        knodes: Map.get(evaluation, :knodes),
        best_move: Map.get(evaluation, :best_move),
        lines: Map.get(evaluation, :lines),
        raw: Map.get(evaluation, :raw)
      }
    }

    case mate do
      value when is_integer(value) and value != 0 -> Map.put(base, :mate_in, value)
      _ -> base
    end
  end

  defp heuristic_summary(%{game: %Game{} = game, status: status}, winner) do
    raw_score =
      case winner do
        :white -> @score_cap
        :black -> -@score_cap
        _ -> evaluate(game)
      end

    score_cp = raw_score |> trunc() |> clamp_score()

    advantage =
      cond do
        winner in [:white, :black] -> winner
        score_cp > 40 -> :white
        score_cp < -40 -> :black
        true -> :equal
      end

    display_score =
      cond do
        winner == :white -> "+M"
        winner == :black -> "-M"
        true -> format_score(score_cp)
      end

    white_percentage =
      cond do
        winner == :white -> 100.0
        winner == :black -> 0.0
        status in [:stalemate, :draw] -> 50.0
        true -> clamp_to_percentage(score_cp)
      end

    %{
      score_cp: score_cp,
      display_score: display_score,
      white_percentage: Float.round(white_percentage, 2),
      advantage: advantage,
      source: :heuristic
    }
  end

  defp heuristic_summary(_state, _winner), do: default_evaluation()

  defp default_evaluation do
    %{
      score_cp: 0,
      display_score: "0.00",
      white_percentage: 50.0,
      advantage: :equal,
      source: :none
    }
  end

  defp log_engine_error(:disabled), do: :ok

  defp log_engine_error(reason) do
    Logger.warning(fn -> "Engine evaluation failed: #{inspect(reason)}" end)
  end

  defp engine_label(:chess_api), do: "Chess API"
  defp engine_label(:stockfish), do: "Stockfish"

  defp engine_label(other) when is_atom(other),
    do: Atom.to_string(other) |> String.replace("_", " ")

  defp engine_label(_), do: "Engine"

  @spec evaluate(Game.t()) :: integer()
  def evaluate(%Game{} = game) do
    material_score(game) +
      piece_square_score(game) +
      development_score(game) +
      queen_pressure(game) +
      check_bonus(game)
  end

  def evaluate(_), do: 0

  defp material_score(%Game{} = game) do
    game
    |> board_map()
    |> Enum.reduce(0, fn {_square, %{color: color, type: type}}, acc ->
      value = Map.get(@piece_values, type, 0)

      case color do
        "w" -> acc + value
        "b" -> acc - value
        _ -> acc
      end
    end)
  end

  defp piece_square_score(%Game{} = game) do
    board = board_map(game)

    Enum.reduce(board, 0, fn {square, %{color: color, type: type}}, acc ->
      table = Map.get(@piece_square_tables, type, @zero_table)

      value =
        case square_coords(square) do
          {file_idx, rank_idx} when color == "w" ->
            Enum.at(table, rank_idx * 8 + file_idx, 0)

          {file_idx, rank_idx} when color == "b" ->
            Enum.at(table, (7 - rank_idx) * 8 + file_idx, 0)

          _ ->
            0
        end

      case color do
        "w" -> acc + value
        "b" -> acc - value
        _ -> acc
      end
    end)
  end

  defp development_score(%Game{} = game) do
    board = board_map(game)

    Enum.reduce(board, 0, fn {square, %{color: color, type: type}}, acc ->
      square_name = square_name(square)

      cond do
        color == "w" and type in ["n", "b"] and
            not MapSet.member?(@white_minor_starts, square_name) ->
          acc + @development_reward

        color == "b" and type in ["n", "b"] and
            not MapSet.member?(@black_minor_starts, square_name) ->
          acc - @development_reward

        true ->
          acc
      end
    end)
  end

  defp queen_pressure(%Game{} = game) do
    board = board_map(game)

    white_bonus = queen_distance_bonus(find_square(board, "w", "q"), find_square(board, "b", "k"))
    black_bonus = queen_distance_bonus(find_square(board, "b", "q"), find_square(board, "w", "k"))

    white_bonus - black_bonus
  end

  defp check_bonus(%Game{check: "w"}), do: @check_bonus
  defp check_bonus(%Game{check: "b"}), do: -@check_bonus
  defp check_bonus(_), do: 0

  defp clamp_to_percentage(score_cp) do
    capped = clamp_score(score_cp)
    (capped + @score_cap) / (2 * @score_cap) * 100
  end

  defp clamp_score(score_cp), do: score_cp |> max(-@score_cap) |> min(@score_cap)

  defp format_score(score_cp) do
    score = score_cp / 100
    formatted = :erlang.float_to_binary(score, [{:decimals, 2}])

    cond do
      score_cp > 0 -> "+" <> formatted
      score_cp < 0 -> formatted
      true -> formatted
    end
  end

  defp board_map(%Game{squares: squares}) when is_map(squares), do: squares
  defp board_map(%Game{squares: squares}) when is_list(squares), do: Map.new(squares)
  defp board_map(_), do: %{}

  defp square_name(square) when is_atom(square),
    do: square |> Atom.to_string() |> String.trim_leading("Elixir.")

  defp square_name(square) when is_binary(square), do: square

  defp square_coords(square) do
    case square_name(square) do
      <<file::utf8, rank::utf8>> -> {file - ?a, rank - ?1}
      _ -> {0, 0}
    end
  end

  defp find_square(board, color, type) do
    Enum.find_value(board, fn {square, %{color: c, type: t}} ->
      if c == color and t == type, do: square, else: nil
    end)
  end

  defp queen_distance_bonus(nil, _king_square), do: 0
  defp queen_distance_bonus(_, nil), do: 0

  defp queen_distance_bonus(queen_square, king_square) do
    {q_file, q_rank} = square_coords(queen_square)
    {k_file, k_rank} = square_coords(king_square)

    distance = max(abs(q_file - k_file), abs(q_rank - k_rank))

    cond do
      distance <= 1 -> 120
      distance == 2 -> 80
      distance == 3 -> 40
      true -> 0
    end
  end
end
