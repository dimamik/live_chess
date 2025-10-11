defmodule LiveChess.GameServer do
  @moduledoc false

  use GenServer

  alias Chess.Game, as: ChessGame

  @type room_id :: String.t()
  @type player_token :: String.t()

  ## Client API

  def start_link(room_id) when is_binary(room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via(room_id))
  end

  def create(room_id, creator_token) do
    GenServer.call(via(room_id), {:create, creator_token})
  end

  def join(room_id, player_token) do
    GenServer.call(via(room_id), {:join, player_token})
  end

  def connect(room_id, player_token) do
    GenServer.call(via(room_id), {:connect, player_token})
  end

  def spectator(room_id, viewer_token) do
    GenServer.call(via(room_id), {:spectator, viewer_token})
  end

  def available_moves(room_id, player_token, from_square) do
    GenServer.call(via(room_id), {:available_moves, player_token, from_square})
  end

  def make_move(room_id, player_token, from, to, promotion \\ "q") do
    GenServer.call(via(room_id), {:move, player_token, from, to, promotion})
  end

  def leave(room_id, player_token) do
    GenServer.cast(via(room_id), {:leave, player_token})
  end

  def get_state(room_id) do
    GenServer.call(via(room_id), :state)
  end

  ## Server callbacks

  @impl true
  def init(room_id) do
    {:ok,
     %{
       room_id: room_id,
       game: ChessGame.new(),
       players: %{
         white: nil,
         black: nil
       },
       spectators: MapSet.new(),
       status: :waiting,
       last_move: nil
     }}
  end

  @impl true
  def handle_call({:create, token}, _from, state) do
    with {:ok, state} <- ensure_slot(state, token, :white) do
      broadcast(state)
      {:reply, {:ok, payload(state, token, :white)}, state}
    end
  end

  def handle_call({:join, token}, _from, state) do
    cond do
      player?(state, token) ->
        color = color_for(state, token)
        updated = put_in(state, [:players, color, :connected?], true)
        maybe_broadcast(state, updated)
        {:reply, {:ok, payload(updated, token, color)}, updated}

      true ->
        with {:ok, state} <- ensure_slot(state, token, :black) do
          state = maybe_activate(state)
          {:reply, {:ok, payload(state, token, :black)}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:connect, token}, _from, state) do
    cond do
      player?(state, token) ->
        color = color_for(state, token)
        updated = put_in(state, [:players, color, :connected?], true)
        maybe_broadcast(state, updated)
        {:reply, {:ok, payload(updated, token, color)}, updated}

      MapSet.member?(state.spectators, token) ->
        {:reply, {:ok, payload(state, token, :spectator)}, state}

      state.status == :waiting ->
        {:reply, {:ok, payload(state, token, :waiting)}, state}

      true ->
        {:reply, {:ok, payload(state, token, :spectator)}, state}
    end
  end

  def handle_call({:spectator, token}, _from, state) do
    spectators = MapSet.put(state.spectators, token)
    updated = %{state | spectators: spectators}
    maybe_broadcast(state, updated)
    {:reply, {:ok, payload(updated, token, :spectator)}, updated}
  end

  def handle_call({:available_moves, token, from}, _from, state) do
    case player_role(state, token) do
      {:player, color} ->
        square = String.downcase(from)

        with {:ok, piece} <- fetch_piece(state.game, square),
             :ok <- ensure_owner(piece, color),
             :ok <- ensure_player_turn(state.game, color) do
          moves = legal_moves_for(state.game, square)
          {:reply, {:ok, moves}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :spectator ->
        {:reply, {:error, :not_authorized}, state}
    end
  end

  def handle_call({:move, token, from, to, promotion}, _from, state) do
    with {:player, color} <- player_role(state, token),
         :active <- state.status,
         :ok <- validate_turn(state, color),
         {:ok, move_value} <- format_move(from, to),
         {:ok, game} <- ChessGame.play(state.game, move_value, promotion) do
      updated =
        state
        |> Map.put(:game, game)
        |> Map.put(:last_move, %{from: from, to: to, promotion: promotion, color: color})
        |> maybe_finish(game)

      broadcast(updated)
      {:reply, {:ok, payload(updated, token, color)}, updated}
    else
      {:player, _} -> {:reply, {:error, :game_not_active}, state}
      :waiting -> {:reply, {:error, :game_not_active}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      :spectator -> {:reply, {:error, :not_authorized}, state}
      {:spectator, _} -> {:reply, {:error, :not_authorized}, state}
    end
  end

  def handle_call(:state, _from, state) do
    {:reply, serialize(state), state}
  end

  @impl true
  def handle_cast({:leave, token}, state) do
    state =
      cond do
        player?(state, token) ->
          color = color_for(state, token)
          updated = put_in(state, [:players, color, :connected?], false)
          maybe_broadcast(state, updated)
          updated

        true ->
          updated = %{state | spectators: MapSet.delete(state.spectators, token)}
          maybe_broadcast(state, updated)
          updated
      end

    {:noreply, state}
  end

  defp ensure_slot(state, token, color) do
    case state.players[color] do
      nil ->
        state = put_in(state, [:players, color], %{token: token, connected?: true})
        {:ok, state}

      %{token: ^token} = player ->
        state = put_in(state, [:players, color], %{player | connected?: true})
        {:ok, state}

      _other ->
        {:error, :slot_taken}
    end
  end

  defp maybe_activate(state) do
    if state.players.white && state.players.black do
      updated = %{state | status: :active}
      broadcast(updated)
      updated
    else
      broadcast(state)
      state
    end
  end

  defp maybe_finish(state, %ChessGame{status: :playing}), do: state

  defp maybe_finish(state, %ChessGame{status: status}) do
    %{state | status: status}
  end

  defp validate_turn(%{game: %ChessGame{current_fen: fen}}, color) do
    case current_turn(fen) do
      ^color -> :ok
      _ -> {:error, :not_your_turn}
    end
  end

  defp current_turn(fen) do
    case String.split(fen, " ") do
      [_board, "w" | _] -> :white
      [_board, "b" | _] -> :black
      _ -> :white
    end
  end

  defp format_move(from, to) do
    if valid_square?(from) and valid_square?(to) do
      {:ok, String.downcase("#{from}-#{to}")}
    else
      {:error, :invalid_square}
    end
  end

  defp valid_square?(square) when is_binary(square) and byte_size(square) == 2 do
    <<file, rank>> = String.downcase(square)
    file in ?a..?h and rank in ?1..?8
  end

  defp valid_square?(_), do: false

  defp fetch_piece(%ChessGame{squares: squares}, square) do
    squares
    |> Map.new()
    |> Map.get(String.to_atom(square))
    |> case do
      nil -> {:error, :empty_square}
      piece -> {:ok, piece}
    end
  end

  defp ensure_owner(%{color: "w"}, :white), do: :ok
  defp ensure_owner(%{color: "b"}, :black), do: :ok
  defp ensure_owner(_piece, _color), do: {:error, :not_authorized}

  defp ensure_player_turn(%ChessGame{current_fen: fen}, color) do
    if current_turn(fen) == color do
      :ok
    else
      {:error, :not_your_turn}
    end
  end

  defp legal_moves_for(%ChessGame{} = game, square) do
    for file <- ?a..?h,
        rank <- ?1..?8,
        to = <<file, rank>>,
        to != square,
        reduce: [] do
      acc ->
        case ChessGame.play(game, square <> "-" <> to, "q") do
          {:ok, _new_game} -> [to | acc]
          {:error, _reason} -> acc
        end
    end
    |> Enum.reverse()
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      LiveChess.PubSub,
      topic(state.room_id),
      {:game_state, serialize(state)}
    )
  end

  defp maybe_broadcast(old_state, new_state) do
    if new_state != old_state do
      broadcast(new_state)
    end
  end

  defp payload(state, token, role) do
    %{role: role, state: serialize(state), player_token: token}
  end

  defp serialize(state) do
    winner =
      case {state.status, state.game.check} do
        {:completed, "w"} -> :white
        {:completed, "b"} -> :black
        _ -> nil
      end

    %{
      room_id: state.room_id,
      status: state.status,
      winner: winner,
      players: serialize_players(state.players),
      last_move: state.last_move,
      board: LiveChess.Games.Board.from_game(state.game),
      turn: current_turn(state.game.current_fen),
      history: Enum.reverse(Enum.map(state.game.history, fn entry -> entry.move end))
    }
  end

  defp serialize_players(players) do
    %{
      white: serialize_player(players.white),
      black: serialize_player(players.black)
    }
  end

  defp serialize_player(nil), do: nil

  defp serialize_player(%{token: token, connected?: connected?}) do
    %{token: token, connected?: connected?}
  end

  defp player?(state, token) do
    Enum.any?([:white, :black], fn color -> match?(%{token: ^token}, state.players[color]) end)
  end

  defp color_for(state, token) do
    cond do
      match?(%{token: ^token}, state.players.white) -> :white
      match?(%{token: ^token}, state.players.black) -> :black
      true -> :spectator
    end
  end

  defp player_role(state, token) do
    cond do
      match?(%{token: ^token}, state.players.white) -> {:player, :white}
      match?(%{token: ^token}, state.players.black) -> {:player, :black}
      true -> :spectator
    end
  end

  defp topic(room_id), do: "game:" <> room_id

  defp via(room_id) do
    {:via, Registry, {LiveChess.GameRegistry, room_id}}
  end
end
