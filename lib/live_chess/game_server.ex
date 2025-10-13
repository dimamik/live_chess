defmodule LiveChess.GameServer do
  @moduledoc false

  use GenServer

  alias Chess.Game, as: ChessGame
  alias LiveChess.Analysis.Evaluator
  alias LiveChess.Games.Storage

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

  def add_robot(room_id, color) do
    GenServer.call(via(room_id), {:add_robot, color})
  end

  def available_moves(room_id, player_token, from_square) do
    GenServer.call(via(room_id), {:available_moves, player_token, from_square})
  end

  def make_move(room_id, player_token, from, to, promotion \\ "q") do
    GenServer.call(via(room_id), {:move, player_token, from, to, promotion})
  end

  def resign(room_id, player_token) do
    GenServer.call(via(room_id), {:resign, player_token})
  end

  def leave(room_id, player_token) do
    GenServer.cast(via(room_id), {:leave, player_token})
  end

  def get_state(room_id) do
    GenServer.call(via(room_id), :state)
  end

  ## Server callbacks

  defp build_timeline(history, current_fen) when is_list(history) do
    {entries, initial_fen} =
      Enum.reduce(history, {[], current_fen}, fn entry, {acc, after_fen} ->
        move = Map.get(entry, :move)
        before_fen = Map.get(entry, :fen)

        timeline_entry = %{
          move: move,
          before_fen: before_fen,
          after_fen: after_fen
        }

        {[timeline_entry | acc], before_fen}
      end)

    timeline =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, index} -> Map.put(entry, :ply, index) end)

    {timeline, initial_fen}
  end

  defp build_timeline(_history, current_fen), do: {[], current_fen}

  @impl true
  def init(room_id) do
    state =
      case Storage.fetch_state(room_id) do
        {:ok, stored_state} -> hydrate_state(stored_state, room_id)
        :error -> new_state(room_id)
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:create, token}, _from, state) do
    color = first_available_color(state)

    with {:ok, state} <- ensure_slot(state, token, color) do
      broadcast(state)
      {:reply, {:ok, payload(state, token, color)}, state}
    end
  end

  def handle_call({:add_robot, color}, _from, state) when color in [:white, :black] do
    cond do
      state.robot != nil ->
        {:reply, {:error, :robot_already_present}, state}

      state.players[color] != nil ->
        {:reply, {:error, :slot_taken}, state}

      true ->
        robot_token = robot_token(state.room_id, color)

        robot_player = %{
          token: robot_token,
          connected?: true,
          robot?: true,
          name: "Robot"
        }

        robot_state = %{color: color, token: robot_token, delay_ms: 700}

        state =
          state
          |> put_in([:players, color], robot_player)
          |> Map.put(:robot, robot_state)

        state = maybe_activate(state)
        state = maybe_queue_robot_move(state)

        {:reply, {:ok, serialize(state)}, state}
    end
  end

  def handle_call({:add_robot, _color}, _from, state) do
    {:reply, {:error, :invalid_color}, state}
  end

  def handle_call({:join, token}, _from, state) do
    cond do
      player?(state, token) ->
        color = color_for(state, token)
        updated = put_in(state, [:players, color, :connected?], true)
        maybe_broadcast(state, updated)
        {:reply, {:ok, payload(updated, token, color)}, updated}

      true ->
        with {:ok, state, color} <- claim_available_slot(state, token) do
          state = maybe_activate(state)
          {:reply, {:ok, payload(state, token, color)}, state}
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
        |> maybe_queue_robot_move()

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

  def handle_call({:resign, token}, _from, state) do
    with {:player, color} <- player_role(state, token),
         true <- game_active?(state) do
      winner = opponent_color(color)

      updated =
        state
        |> Map.put(:status, :resigned)
        |> Map.put(:winner, winner)
        |> Map.put(:last_move, %{action: :resigned, color: color})
        |> cancel_robot_timer()

      broadcast(updated)
      {:reply, {:ok, payload(updated, token, color)}, updated}
    else
      :spectator -> {:reply, {:error, :not_authorized}, state}
      false -> {:reply, {:error, :game_not_active}, state}
      {:player, _} -> {:reply, {:error, :game_not_active}, state}
    end
  end

  def handle_call(:state, _from, state) do
    {:reply, serialize(state), state}
  end

  @impl true
  def handle_info(:robot_move, state) do
    state = %{state | robot_timer: nil}

    case perform_robot_move(state) do
      {:ok, updated} -> {:noreply, updated}
      {:error, _reason} -> {:noreply, state}
    end
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

  defp claim_available_slot(state, token) do
    cond do
      state.players.white == nil ->
        with {:ok, state} <- ensure_slot(state, token, :white) do
          {:ok, state, :white}
        end

      state.players.black == nil ->
        with {:ok, state} <- ensure_slot(state, token, :black) do
          {:ok, state, :black}
        end

      true ->
        {:error, :slot_taken}
    end
  end

  defp maybe_activate(state) do
    if state.players.white && state.players.black do
      updated = %{state | status: :active, winner: nil}
      broadcast(updated)
      updated
    else
      broadcast(state)
      state
    end
  end

  defp maybe_finish(state, %ChessGame{status: status}) when status in [:playing, :check] do
    state
    |> Map.put(:status, :active)
    |> Map.put(:winner, nil)
  end

  defp maybe_finish(state, %ChessGame{status: status}) do
    %{state | status: status, winner: Map.get(state, :winner)}
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
    sanitized = persistable_state(state)

    _ = Storage.persist_state(sanitized)

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
    checking_color =
      case state.game.check do
        "w" -> :white
        "b" -> :black
        _ -> nil
      end

    in_check =
      case checking_color do
        :white -> :black
        :black -> :white
        _ -> nil
      end

    winner =
      Map.get(state, :winner) ||
        case {state.status, checking_color} do
          {:completed, :white} -> :white
          {:completed, :black} -> :black
          _ -> nil
        end

    evaluation = Evaluator.summary(state, winner)
    {timeline, initial_fen} = build_timeline(state.game.history, state.game.current_fen)

    %{
      room_id: state.room_id,
      status: state.status,
      winner: winner,
      checking_color: checking_color,
      in_check: in_check,
      players: serialize_players(state.players),
      last_move: state.last_move,
      board: LiveChess.Games.Board.from_game(state.game),
      turn: current_turn(state.game.current_fen),
      history: Enum.map(timeline, & &1.move),
      timeline: timeline,
      initial_fen: initial_fen,
      current_fen: state.game.current_fen,
      evaluation: evaluation
    }
  end

  defp serialize_players(players) do
    %{
      white: serialize_player(players.white),
      black: serialize_player(players.black)
    }
  end

  defp serialize_player(nil), do: nil

  defp serialize_player(%{token: token, connected?: connected?} = player) do
    base = %{token: token, connected?: connected?}

    base =
      if Map.get(player, :robot?) do
        Map.put(base, :robot?, true)
      else
        base
      end

    case Map.get(player, :name) do
      nil -> base
      name -> Map.put(base, :name, name)
    end
  end

  defp first_available_color(state) do
    cond do
      is_nil(state.players.white) -> :white
      is_nil(state.players.black) -> :black
      true -> Enum.random([:white, :black])
    end
  end

  defp player?(state, token) do
    Enum.any?([:white, :black], fn color -> match?(%{token: ^token}, state.players[color]) end)
  end

  defp new_state(room_id) do
    %{
      room_id: room_id,
      game: ChessGame.new(),
      players: %{
        white: nil,
        black: nil
      },
      spectators: MapSet.new(),
      status: :waiting,
      last_move: nil,
      winner: nil,
      robot: nil,
      robot_timer: nil
    }
  end

  defp hydrate_state(state, room_id) when is_map(state) do
    state
    |> Map.put(:room_id, room_id)
    |> Map.update(:spectators, MapSet.new(), fn
      %MapSet{} = set -> set
      other when is_list(other) -> MapSet.new(other)
      _ -> MapSet.new()
    end)
    |> Map.put_new(:winner, nil)
    |> Map.put_new(:robot, nil)
    |> Map.put(:robot_timer, nil)
  end

  defp hydrate_state(_state, room_id), do: new_state(room_id)

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

  defp game_active?(%{status: status}) do
    status in [:active]
  end

  defp game_active?(_), do: false

  defp opponent_color(:white), do: :black
  defp opponent_color(:black), do: :white
  defp opponent_color(_), do: nil

  defp robot_token(room_id, color), do: "robot:#{room_id}:#{color}"

  defp robot_turn?(%{robot: %{color: color}} = state) do
    state.status == :active and current_turn(state.game.current_fen) == color
  end

  defp robot_turn?(_), do: false

  defp robot_delay(%{robot: %{delay_ms: delay}}) when is_integer(delay) do
    delay
  end

  defp robot_delay(_), do: 600

  defp maybe_queue_robot_move(%{robot: nil} = state), do: cancel_robot_timer(state)

  defp maybe_queue_robot_move(state) do
    cond do
      robot_turn?(state) ->
        case state.robot_timer do
          nil ->
            ref = Process.send_after(self(), :robot_move, robot_delay(state))
            %{state | robot_timer: ref}

          _ref ->
            state
        end

      true ->
        cancel_robot_timer(state)
    end
  end

  defp cancel_robot_timer(%{robot_timer: nil} = state), do: state

  defp cancel_robot_timer(state) do
    _ = Process.cancel_timer(state.robot_timer)
    %{state | robot_timer: nil}
  end

  defp perform_robot_move(%{robot: %{color: color}} = state) do
    with true <- state.status == :active,
         true <- current_turn(state.game.current_fen) == color,
         {:ok, %{from: from, to: to, promotion: promotion}} <- robot_pick_move(state.game, color),
         {:ok, game} <- ChessGame.play(state.game, String.downcase("#{from}-#{to}"), promotion) do
      updated =
        state
        |> Map.put(:game, game)
        |> Map.put(:last_move, %{
          from: from,
          to: to,
          promotion: promotion,
          color: color,
          robot?: true
        })
        |> maybe_finish(game)
        |> maybe_queue_robot_move()

      broadcast(updated)
      {:ok, updated}
    else
      _ -> {:error, :unable_to_move}
    end
  end

  defp perform_robot_move(state), do: {:ok, state}

  defp robot_pick_move(game, color) do
    game
    |> robot_move_candidates(color)
    |> case do
      [] -> {:error, :no_moves}
      moves -> {:ok, Enum.random(moves)}
    end
  end

  defp robot_move_candidates(game, color) do
    for file <- ?a..?h,
        rank <- ?1..?8,
        square = <<file, rank>>,
        {:ok, piece} <- [fetch_piece(game, square)],
        robot_piece?(piece, color),
        dest <- legal_moves_for(game, square) do
      %{from: String.downcase(square), to: dest, promotion: robot_promotion(piece, dest)}
    end
  end

  defp robot_piece?(%{color: "w"}, :white), do: true
  defp robot_piece?(%{color: "b"}, :black), do: true
  defp robot_piece?(_, _), do: false

  defp robot_promotion(%{role: :pawn}, destination) when is_binary(destination) do
    case String.last(destination) do
      "8" -> "q"
      "1" -> "q"
      _ -> "q"
    end
  end

  defp robot_promotion(%{type: :pawn}, destination) when is_binary(destination) do
    case String.last(destination) do
      "8" -> "q"
      "1" -> "q"
      _ -> "q"
    end
  end

  defp robot_promotion(_piece, _destination), do: "q"

  defp persistable_state(state) do
    state
    |> Map.put(:robot_timer, nil)
  end

  defp topic(room_id), do: "game:" <> room_id

  defp via(room_id) do
    {:via, Registry, {LiveChess.GameRegistry, room_id}}
  end
end
