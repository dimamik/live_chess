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
      assert {:ok, %{state: state}} = Games.connect(room_id, host_token)
      assert state.players.white.token == host_token
      assert state.status == :waiting

      assert %{
               display_score: _,
               white_percentage: percent,
               advantage: _
             } = state.evaluation

      assert is_number(percent)
      assert state.evaluation.source in [:heuristic, :stockfish, :chess_api, :none]

      guest_token = Games.generate_player_token()
      assert {:ok, %{role: :black}} = Games.join_game(room_id, guest_token)
      assert {:ok, %{state: state_after_join}} = Games.connect(room_id, guest_token)
      assert state_after_join.status == :active
      assert is_map(state_after_join.evaluation)
      assert state_after_join.evaluation.source in [:heuristic, :stockfish, :chess_api, :none]

      assert {:ok, %{state: move_state}} = Games.make_move(room_id, host_token, "e2", "e4")
      assert move_state.history == ["e4"]
      assert move_state.turn == :black

      assert {:error, :not_your_turn} = Games.make_move(room_id, host_token, "d2", "d4")
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
