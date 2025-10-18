defmodule LiveChess.GamesTest do
  use ExUnit.Case, async: false

  alias LiveChess.Games

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LiveChess.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LiveChess.Repo, {:shared, self()})
    :ok
  end

  describe "in-memory game flow" do
    test "players can create, join, and make moves" do
      host_token = Games.generate_player_token()

      assert {:ok, room_id} = Games.create_game(host_token)
      assert {:ok, %{role: host_color, state: state}} = Games.connect(room_id, host_token)

      # Host gets randomly assigned white or black
      assert host_color in [:white, :black]
      assert state.players[host_color].token == host_token
      assert state.status == :waiting

      # Evaluation is now client-side only, may be nil until client sends it
      assert state.evaluation == nil or is_map(state.evaluation)

      guest_token = Games.generate_player_token()
      guest_color = if host_color == :white, do: :black, else: :white
      assert {:ok, %{role: ^guest_color}} = Games.join_game(room_id, guest_token)
      assert {:ok, %{state: state_after_join}} = Games.connect(room_id, guest_token)
      assert state_after_join.status == :active
      # Evaluation comes from client-side WASM Stockfish
      assert state_after_join.evaluation == nil or is_map(state_after_join.evaluation)

      # Make a move with whoever is white (always goes first)
      white_token = if host_color == :white, do: host_token, else: guest_token
      black_token = if host_color == :black, do: host_token, else: guest_token

      assert {:ok, %{state: move_state}} = Games.make_move(room_id, white_token, "e2", "e4")
      assert move_state.history == ["e4"]
      assert move_state.turn == :black

      # White cannot move again (not their turn)
      assert {:error, :not_your_turn} = Games.make_move(room_id, white_token, "d2", "d4")

      # Black can move
      assert {:ok, %{state: _}} = Games.make_move(room_id, black_token, "e7", "e5")
    end

    test "cannot join when seats taken" do
      host_token = Games.generate_player_token()
      {:ok, room_id} = Games.create_game(host_token)

      guest_token = Games.generate_player_token()
      {:ok, _} = Games.join_game(room_id, guest_token)

      late_token = Games.generate_player_token()
      assert {:error, :slot_taken} = Games.join_game(room_id, late_token)
    end
  end
end
