defmodule LiveChess.Games.Notation do
  @moduledoc false

  alias Chess.Game, as: ChessGame

  @type annotated_move :: %{
          optional(:ply) => integer() | nil,
          optional(:move) => String.t() | nil,
          required(:san) => String.t(),
          optional(:from) => String.t() | nil,
          optional(:to) => String.t() | nil,
          optional(:color) => :white | :black
        }

  @spec annotate(list(map())) :: [annotated_move]
  def annotate(timeline) when is_list(timeline) do
    Enum.map(timeline, &annotate_entry/1)
  end

  def annotate(_), do: []

  defp square_map(%{} = squares), do: squares
  defp square_map(squares) when is_list(squares), do: Map.new(squares)
  defp square_map(_), do: %{}

  defp annotate_entry(%{move: move} = entry) do
    ply = Map.get(entry, :ply)

    with {:ok, from, to} <- parse_move(move),
         {:ok, before_game} <- load_game(Map.get(entry, :before_fen)),
         {:ok, after_game} <- load_game(Map.get(entry, :after_fen)),
         %{type: type} = piece when is_binary(type) <- fetch_piece(before_game, from) do
      san =
        build_san(
          from,
          to,
          piece,
          before_game,
          after_game,
          Map.get(entry, :before_fen)
        )

      %{
        ply: ply,
        move: move,
        from: from,
        to: to,
        san: san,
        color: ply_color(ply)
      }
    else
      _ -> fallback_entry(ply, move)
    end
  end

  defp annotate_entry(entry) do
    fallback_entry(Map.get(entry, :ply), Map.get(entry, :move))
  end

  defp fallback_entry(ply, move) do
    %{
      ply: ply,
      move: move,
      from: nil,
      to: nil,
      san: move || "",
      color: ply_color(ply)
    }
  end

  defp parse_move(<<from::binary-size(2), "-", to::binary-size(2)>>) do
    {:ok, String.downcase(from), String.downcase(to)}
  end

  defp parse_move(_), do: :error

  defp load_game(fen) when is_binary(fen) do
    {:ok, ChessGame.new(fen)}
  rescue
    _ -> {:error, :invalid_fen}
  end

  defp load_game(_), do: {:error, :invalid_fen}

  # sobelow_skip ["DOS.StringToAtom"]
  # Safe: square is a chess board coordinate (a1-h8) validated by the chess library.
  # Limited to 64 valid square names, preventing atom table exhaustion.
  defp fetch_piece(%ChessGame{squares: squares}, square) do
    squares
    |> square_map()
    |> Map.get(String.to_atom(square))
  end

  defp build_san(from, to, %{type: "k"} = piece, before_game, after_game, before_fen) do
    cond do
      castling_kingside?(piece, from, to) ->
        "O-O" <> move_suffix(after_game)

      castling_queenside?(piece, from, to) ->
        "O-O-O" <> move_suffix(after_game)

      true ->
        build_standard_san(from, to, piece, before_game, after_game, before_fen)
    end
  end

  defp build_san(from, to, piece, before_game, after_game, before_fen) do
    build_standard_san(from, to, piece, before_game, after_game, before_fen)
  end

  defp build_standard_san(from, to, %{type: type} = piece, before_game, after_game, before_fen) do
    capture? = capture?(piece, to, before_game, before_fen)

    prefix =
      case type do
        "p" -> pawn_prefix(from, capture?)
        _ -> piece_letter(type) <> disambiguation(piece, from, to, before_game, before_fen)
      end

    destination = String.downcase(to)
    promotion_suffix = promotion_suffix(piece, to, after_game)

    prefix <>
      if(capture?, do: "x", else: "") <>
      destination <>
      promotion_suffix <>
      move_suffix(after_game)
  end

  defp castling_kingside?(%{type: "k"}, from, to) do
    {from, to} in [{"e1", "g1"}, {"e8", "g8"}]
  end

  defp castling_kingside?(_, _, _), do: false

  defp castling_queenside?(%{type: "k"}, from, to) do
    {from, to} in [{"e1", "c1"}, {"e8", "c8"}]
  end

  defp castling_queenside?(_, _, _), do: false

  defp pawn_prefix(from, true), do: String.slice(from, 0, 1)
  defp pawn_prefix(_from, _capture?), do: ""

  defp piece_letter(type) when is_binary(type), do: String.upcase(type)
  defp piece_letter(_), do: ""

  defp disambiguation(%{type: "p"}, _from, _to, _before_game, _before_fen), do: ""

  defp disambiguation(piece, from, to, %ChessGame{} = before_game, before_fen) do
    same_type_candidates(
      before_game,
      piece,
      from,
      to,
      before_fen
    )
    |> case do
      [] ->
        ""

      candidates ->
        file = file(from)
        rank = rank(from)
        file_conflict? = Enum.any?(candidates, &(file(&1) == file))
        rank_conflict? = Enum.any?(candidates, &(rank(&1) == rank))

        cond do
          not file_conflict? -> file
          not rank_conflict? -> rank
          true -> from
        end
    end
  end

  defp same_type_candidates(
         %ChessGame{squares: squares},
         %{type: type, color: color},
         from,
         to,
         before_fen
       ) do
    squares = square_map(squares)

    squares
    |> Enum.filter(fn {_, %{type: other_type, color: other_color}} ->
      other_type == type and other_color == color
    end)
    |> Enum.map(fn {square, _} -> Atom.to_string(square) end)
    |> Enum.reject(&(&1 == from))
    |> Enum.filter(&legal_move?(before_fen, &1, to))
  end

  defp legal_move?(fen, from, to) when is_binary(fen) and is_binary(from) and is_binary(to) do
    case ChessGame.play(ChessGame.new(fen), "#{from}-#{to}", "q") do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp legal_move?(_, _, _), do: false

  # sobelow_skip ["DOS.StringToAtom"]
  # Safe: 'to' is a chess board coordinate (a1-h8) validated by the chess library.
  # Limited to 64 valid square names, preventing atom table exhaustion.
  defp capture?(piece, to, %ChessGame{squares: squares} = before_game, before_fen) do
    target = square_map(squares) |> Map.get(String.to_atom(to))

    cond do
      target != nil ->
        true

      piece.type == "p" ->
        en_passant_target(before_fen) == to and pawn_en_passant_possible?(piece, to, before_game)

      true ->
        false
    end
  end

  defp pawn_en_passant_possible?(_piece, _to, %ChessGame{squares: squares}) do
    # If the destination square is empty but matches the en passant target,
    # treat it as a capture. The en passant victim will be removed in the
    # underlying chess library, so we only need to acknowledge the capture here.
    squares
    |> square_map()
    |> Enum.any?(fn {_square, value} -> match?(%{type: "p"}, value) end)
  end

  defp en_passant_target(fen) when is_binary(fen) do
    case String.split(fen, " ") do
      [_board, _active, _castling, target | _] -> if target == "-", do: nil, else: target
      _ -> nil
    end
  end

  defp en_passant_target(_), do: nil

  # sobelow_skip ["DOS.StringToAtom"]
  # 'to' is a chess board coordinate (a1-h8) validated by the chess library.
  # Limited to 64 valid square names, preventing atom table exhaustion.
  defp promotion_suffix(%{type: "p"}, to, %ChessGame{squares: squares}) do
    case square_map(squares) |> Map.get(String.to_atom(to)) do
      %{type: type} when type != "p" -> "=" <> String.upcase(type)
      _ -> ""
    end
  end

  defp promotion_suffix(_, _to, _after_game), do: ""

  defp move_suffix(%ChessGame{status: :completed}), do: "#"
  defp move_suffix(%ChessGame{status: :check}), do: "+"
  defp move_suffix(_), do: ""

  defp file(square) when is_binary(square), do: String.slice(square, 0, 1)
  defp rank(square) when is_binary(square), do: String.slice(square, 1, 1)

  defp ply_color(ply) when is_integer(ply) do
    if rem(ply, 2) == 1, do: :white, else: :black
  end

  defp ply_color(_), do: :white
end
