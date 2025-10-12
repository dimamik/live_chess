defmodule LiveChess.Games do
  @moduledoc """
  Public API for managing in-memory chess games.
  """

  alias LiveChess.{GameServer, GameSupervisor}

  @room_length 6

  def generate_player_token do
    10
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def create_game(creator_token) do
    room_id = unique_room_id()

    with {:ok, _pid} <- GameSupervisor.start_game(room_id),
         {:ok, %{role: _role}} <- GameServer.create(room_id, creator_token) do
      {:ok, room_id}
    else
      {:ok, :already_started} -> GameServer.create(room_id, creator_token)
      {:error, reason} -> {:error, reason}
    end
  end

  def join_game(room_id, token) do
    with_server(room_id, fn -> GameServer.join(room_id, token) end)
  end

  def connect(room_id, token) do
    with_server(room_id, fn -> GameServer.connect(room_id, token) end)
  end

  def spectate(room_id, token) do
    with_server(room_id, fn -> GameServer.spectator(room_id, token) end)
  end

  def leave(room_id, token) do
    with_server(room_id, fn -> GameServer.leave(room_id, token) end)
  end

  def make_move(room_id, token, from, to, promotion \\ "q") do
    with_server(room_id, fn -> GameServer.make_move(room_id, token, from, to, promotion) end)
  end

  def game_state(room_id) do
    with_server(room_id, fn -> GameServer.get_state(room_id) end)
  end

  def available_moves(room_id, token, from_square) do
    with_server(room_id, fn -> GameServer.available_moves(room_id, token, from_square) end)
  end

  def subscribe(room_id) do
    Phoenix.PubSub.subscribe(LiveChess.PubSub, "game:" <> room_id)
  end

  defp unique_room_id do
    room_id =
      Base.encode32(:crypto.strong_rand_bytes(5), padding: false)
      |> String.slice(0, @room_length)
      |> String.downcase()

    case Registry.lookup(LiveChess.GameRegistry, room_id) do
      [] -> room_id
      _ -> unique_room_id()
    end
  end

  defp with_server(room_id, fun) do
    case Registry.lookup(LiveChess.GameRegistry, room_id) do
      [] -> {:error, :not_found}
      _ -> fun.()
    end
  end
end
