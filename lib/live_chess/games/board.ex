defmodule LiveChess.Games.Board do
  @moduledoc false

  alias Chess.Game, as: ChessGame

  @files ~w(a b c d e f g h)
  @ranks Enum.to_list(1..8)

  def from_game(%ChessGame{squares: squares}) do
    square_map = Map.new(squares)

    for rank <- Enum.reverse(@ranks) do
      for file <- @files do
        key = "#{file}#{rank}"
        {:ok, piece} = normalize_piece(square_map, key)

        %{
          id: key,
          file: file,
          rank: rank,
          light?: light_square?(file, rank),
          piece: piece
        }
      end
    end
  end

  def oriented(board, :white), do: board

  def oriented(board, :black) do
    board
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
  end

  def oriented(board, _), do: board

  defp normalize_piece(squares, key) do
    case Map.get(squares, String.to_atom(key)) do
      nil -> {:ok, nil}
      %{color: color, type: type} -> {:ok, %{color: normalize_color(color), type: type}}
      _ -> {:ok, nil}
    end
  end

  defp normalize_color("w"), do: :white
  defp normalize_color("b"), do: :black
  defp normalize_color(color), do: color

  defp light_square?(file, rank) do
    file_index = Enum.find_index(@files, fn item -> item == file end)
    rem(file_index + rank, 2) == 0
  end
end
