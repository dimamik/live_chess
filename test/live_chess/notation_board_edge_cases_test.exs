defmodule NotationBoardEdgeCasesTest do
  use ExUnit.Case, async: true

  alias LiveChess.Games.Board
  alias LiveChess.Games.Notation
  alias Chess.Game, as: ChessGame

  defp san(before_fen, move) do
    {:ok, game} = ChessGame.play(ChessGame.new(before_fen), move)

    [entry] =
      Notation.annotate([
        %{ply: 1, move: move, before_fen: before_fen, after_fen: game.current_fen}
      ])

    entry.san
  end

  test "pawn promotion: e8=Q" do
    before_fen = "8/4P3/8/8/8/2k5/8/K7 w - - 0 1"
    assert san(before_fen, "e7-e8") == "e8=Q"
  end

  test "pawn capture-promotion: dxe8=Q" do
    before_fen = "4r3/3P4/8/8/8/2k5/8/K7 w - - 0 1"
    assert san(before_fen, "d7-e8") == "dxe8=Q"
  end

  test "kingside castling with check: O-O+" do
    before_fen = "5k2/8/8/8/8/8/8/4K2R w K - 0 1"
    assert san(before_fen, "e1-g1") == "O-O+"
  end

  test "two queens on same rank disambiguate by file: Qad4" do
    before_fen = "k6K/8/8/8/Q6Q/8/8/8 w - - 0 1"
    assert san(before_fen, "a4-d4") == "Qad4"
  end

  test "two rooks on same file disambiguate by rank: R3a4" do
    before_fen = "4k3/8/R7/8/8/R7/8/4K3 w - - 0 1"
    assert san(before_fen, "a3-a4") == "R3a4"
  end

  test "en passant capture: exd6" do
    before_fen = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 3"
    assert san(before_fen, "e5-d6") == "exd6"
  end

  # Pinned candidate must be excluded from disambiguation.
  # Knights on c3 and e3 both reach d5, but c3 is absolutely pinned by Rc8
  # against Kc1, so Ne3-d5 needs no disambiguation.
  test "pinned knight candidate excluded: just Nd5" do
    before_fen = "2r5/8/8/8/8/2N1N3/8/2K4k w - - 0 1"
    assert san(before_fen, "e3-d5") == "Nd5"
  end

  test "board coloring: a1 dark, h1 light, a8 light, h8 dark" do
    board = Board.from_game(ChessGame.new())
    squares = List.flatten(board)
    assert Enum.find(squares, &(&1.id == "a1")).light? == false
    assert Enum.find(squares, &(&1.id == "h1")).light? == true
    assert Enum.find(squares, &(&1.id == "a8")).light? == true
    assert Enum.find(squares, &(&1.id == "h8")).light? == false
  end
end
