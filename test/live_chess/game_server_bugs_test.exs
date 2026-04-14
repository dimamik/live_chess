defmodule LiveChess.GameServerBugsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias LiveChess.{Games, GameServer, GameSupervisor}

  setup do
    :ok = Sandbox.checkout(LiveChess.Repo)
    Sandbox.mode(LiveChess.Repo, {:shared, self()})

    room_id = "test_#{:erlang.unique_integer([:positive])}"
    player_token = Games.generate_player_token()
    opponent_token = Games.generate_player_token()

    %{room_id: room_id, player_token: player_token, opponent_token: opponent_token}
  end

  defp start_with_colors(room_id, token_a, token_b) do
    {:ok, _pid} = GameSupervisor.start_game(room_id)
    {:ok, %{role: first_color}} = GameServer.create(room_id, token_a)

    {:ok, _} = GameServer.join(room_id, token_b)

    # Return {white_token, black_token} based on which side token_a took
    if first_color == :white, do: {token_a, token_b}, else: {token_b, token_a}
  end

  defp play_moves(room_id, white, black, moves) do
    moves
    |> Enum.with_index()
    |> Enum.each(fn {{from, to}, idx} ->
      token = if rem(idx, 2) == 0, do: white, else: black
      {:ok, _} = GameServer.make_move(room_id, token, from, to, "q")
    end)
  end

  describe "Bug 1 fixed: move after checkmate returns error, not crash" do
    test "returns :game_not_active instead of crashing", %{
      room_id: room_id,
      player_token: pt,
      opponent_token: ot
    } do
      {white, black} = start_with_colors(room_id, pt, ot)

      # Fool's mate: 1. f3 e5  2. g4 Qh4#
      play_moves(room_id, white, black, [
        {"f2", "f3"},
        {"e7", "e5"},
        {"g2", "g4"},
        {"d8", "h4"}
      ])

      state = GameServer.get_state(room_id)
      assert state.status == :completed

      # Before the fix: raised WithClauseError and crashed the GenServer.
      # After the fix: returns a clean {:error, :game_not_active}.
      assert {:error, :game_not_active} =
               GameServer.make_move(room_id, white, "a2", "a3", "q")

      # GenServer should still be alive to respond to other calls.
      assert %{status: :completed} = GameServer.get_state(room_id)
    end
  end

  describe "Bug 2 fixed: invalid promotion char returns error, not crash" do
    test "returns :invalid_promotion instead of crashing", %{
      room_id: room_id,
      player_token: pt,
      opponent_token: ot
    } do
      {white, _black} = start_with_colors(room_id, pt, ot)

      assert {:error, :invalid_promotion} =
               GameServer.make_move(room_id, white, "e2", "e4", "x")

      # The server is still alive.
      assert %{} = GameServer.get_state(room_id)
    end

    test "still accepts valid promotion chars",
         %{room_id: room_id, player_token: pt, opponent_token: ot} do
      {white, _black} = start_with_colors(room_id, pt, ot)

      # "q" is valid (default); normal move shouldn't error out on validation.
      assert {:ok, _} = GameServer.make_move(room_id, white, "e2", "e4", "q")
    end
  end

  describe "Bug 3 fixed: create on full room returns clean error, not crash" do
    test "returns {:error, :slot_taken} and keeps server alive", %{
      room_id: room_id,
      player_token: pt,
      opponent_token: ot
    } do
      {_white, _black} = start_with_colors(room_id, pt, ot)

      third_token = Games.generate_player_token()

      # Before the fix: exited with {:bad_return_value, {:error, :slot_taken}}.
      # After the fix: returns the error cleanly.
      assert {:error, :slot_taken} = GameServer.create(room_id, third_token)

      # Server still responsive.
      assert %{} = GameServer.get_state(room_id)
    end
  end

  describe "Bug 4 fixed: spectator move returns error, not crash" do
    test "spectator attempting a move receives {:error, :not_authorized}", %{
      room_id: room_id,
      player_token: pt,
      opponent_token: ot
    } do
      {_white, _black} = start_with_colors(room_id, pt, ot)

      spectator = Games.generate_player_token()

      assert {:error, :not_authorized} =
               GameServer.make_move(room_id, spectator, "e2", "e4", "q")

      assert %{} = GameServer.get_state(room_id)
    end
  end

  describe "sanity checks on existing behavior" do
    test "available_moves error paths still work",
         %{room_id: room_id, player_token: pt, opponent_token: ot} do
      {white, black} = start_with_colors(room_id, pt, ot)

      assert {:error, :not_your_turn} = GameServer.available_moves(room_id, black, "e7")
      assert {:error, :empty_square} = GameServer.available_moves(room_id, white, "e4")
    end
  end
end
