defmodule LiveChessWeb.GameLive do
  use LiveChessWeb, :live_view

  alias Chess.Game, as: ChessGame
  alias LiveChess.Games
  alias LiveChess.Games.Board
  alias LiveChess.Games.Notation
  alias LiveChessWeb.Presence

  @auto_join_retry_ms 1_500

  @finished_statuses [
    :completed,
    :checkmate,
    :stalemate,
    :draw,
    :insufficient_material,
    :threefold_repetition,
    :fifty_move_rule,
    :timeout,
    :resigned,
    :abandoned
  ]

  @impl true
  def mount(%{"room_id" => room_id}, _session, socket) do
    socket =
      socket
      |> assign(:room_id, room_id)
      |> assign(:selected_square, nil)
      |> assign(:available_moves, MapSet.new())
      |> assign(:error_message, nil)
      |> assign(:role, :spectator)
      |> assign(:game, nil)
      |> assign(:share_url, build_share_url(room_id))
      |> assign(:player_token, socket.assigns.player_token)
      |> assign(:board_ready?, false)
      |> assign(:show_leave_modal, false)
      |> assign(:show_surrender_modal, false)
      |> assign(:board_override, nil)
      |> assign(:active_last_move, nil)
      |> assign(:history_cursor, nil)
      |> assign(:history_length, 0)
      |> assign(:history_status, "No moves yet.")
      |> assign(:history_entries, [])
      |> assign(:history_pairs, [])
      |> assign(:history_selected_ply, nil)
      |> assign(:endgame_overlay_dismissed, false)
      |> assign(:auto_join_attempt, %{target: nil, attempted_at: nil})
      |> assign(:page_title, "LiveView Chess")

    if connected?(socket) do
      Games.subscribe(room_id)

      # Subscribe to presence updates
      topic = "game:#{room_id}"
      Phoenix.PubSub.subscribe(LiveChess.PubSub, topic)

      case Games.connect(room_id, socket.assigns.player_token) do
        {:ok, %{role: role, state: state}} ->
          # Track this connection in Presence
          {:ok, _} =
            Presence.track(self(), topic, socket.assigns.player_token, %{
              role: role,
              joined_at: System.system_time(:second),
              online_at: inspect(System.system_time(:second))
            })

          socket =
            socket
            |> assign(:role, role)
            |> assign(:board_ready?, true)
            |> assign(:presence_topic, topic)
            |> update_spectator_count_from_presence(topic)

          socket =
            socket
            |> set_game_state(state)
            |> set_final_evaluation_if_finished(state)
            |> request_client_evaluation(state)
            |> maybe_request_robot_move(state)

          {:ok, maybe_auto_join(socket, state)}

        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, "That room does not exist or has expired.")
           |> push_navigate(to: ~p"/")}

        {:error, _reason} ->
          {:ok,
           socket
           |> put_flash(:error, "We couldn't connect you to that room. Try again from the lobby.")
           |> push_navigate(to: ~p"/")}
      end
    else
      case Games.game_state(room_id) do
        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, "That room does not exist or has expired.")
           |> push_navigate(to: ~p"/")}

        {:error, _reason} ->
          {:ok,
           socket
           |> put_flash(:error, "We couldn't connect you to that room. Try again from the lobby.")
           |> push_navigate(to: ~p"/")}

        state when is_map(state) ->
          role =
            determine_initial_role(
              state,
              socket.assigns.player_token,
              socket.assigns.role
            )

          {:ok,
           socket
           |> assign(:role, role)
           |> set_game_state(state)}

        _ ->
          {:ok, socket}
      end
    end
  end

  @impl true
  def handle_event("request_home", _params, socket) do
    if game_pending?(socket.assigns.game) do
      {:noreply, assign(socket, :show_leave_modal, true)}
    else
      {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  def handle_event("cancel_leave", _params, socket) do
    {:noreply, assign(socket, :show_leave_modal, false)}
  end

  def handle_event("confirm_leave", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_leave_modal, false)
     |> push_navigate(to: ~p"/")}
  end

  def handle_event("request_surrender", _params, socket) do
    if show_surrender_button?(socket.assigns.role, socket.assigns.game) do
      {:noreply, assign(socket, :show_surrender_modal, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_surrender", _params, socket) do
    {:noreply, assign(socket, :show_surrender_modal, false)}
  end

  def handle_event("confirm_surrender", _params, socket) do
    if show_surrender_button?(socket.assigns.role, socket.assigns.game) do
      case Games.resign(socket.assigns.room_id, socket.assigns.player_token) do
        {:ok, %{state: state}} ->
          {:noreply,
           socket
           |> assign(:show_surrender_modal, false)
           |> set_game_state(state)
           |> assign(:error_message, nil)}

        {:error, :game_not_active} ->
          {:noreply,
           socket
           |> assign(:show_surrender_modal, false)
           |> assign(:error_message, "The game is no longer active.")}

        {:error, :not_authorized} ->
          {:noreply,
           socket
           |> assign(:show_surrender_modal, false)
           |> assign(:error_message, "Only seated players can surrender.")}

        {:error, message} when is_binary(message) ->
          {:noreply,
           socket
           |> assign(:show_surrender_modal, false)
           |> assign(:error_message, message)}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(:show_surrender_modal, false)
           |> assign(:error_message, "Unable to surrender right now.")}
      end
    else
      {:noreply, assign(socket, :show_surrender_modal, false)}
    end
  end

  def handle_event("history_prev", _params, socket) do
    current = socket.assigns.history_cursor || socket.assigns.history_length
    {:noreply, update_history_cursor(socket, current - 1)}
  end

  def handle_event("history_next", _params, socket) do
    current = socket.assigns.history_cursor || socket.assigns.history_length
    {:noreply, update_history_cursor(socket, current + 1)}
  end

  def handle_event("history_live", _params, socket) do
    {:noreply, update_history_cursor(socket, socket.assigns.history_length)}
  end

  def handle_event("escape_press", _params, socket) do
    cond do
      overlay_active?(socket) ->
        {:noreply, assign(socket, :endgame_overlay_dismissed, true)}

      socket.assigns[:show_surrender_modal] ->
        {:noreply, assign(socket, :show_surrender_modal, false)}

      socket.assigns[:show_leave_modal] ->
        {:noreply, assign(socket, :show_leave_modal, false)}

      show_surrender_button?(socket.assigns.role, socket.assigns.game) ->
        {:noreply, assign(socket, :show_surrender_modal, true)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("dismiss_endgame_overlay", _params, socket) do
    {:noreply, assign(socket, :endgame_overlay_dismissed, true)}
  end

  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("client_eval_result", %{"evaluation" => evaluation}, socket) do
    # Update game state with client-side evaluation
    # Keep as strings from JavaScript
    normalized_evaluation = %{
      "score_cp" => Map.get(evaluation, "score_cp"),
      "display_score" => Map.get(evaluation, "display_score"),
      "white_percentage" => Map.get(evaluation, "white_percentage"),
      "advantage" => Map.get(evaluation, "advantage", "equal"),
      "source" => Map.get(evaluation, "source", "stockfish_wasm")
    }

    game = socket.assigns.game

    if game do
      updated_game = Map.put(game, :evaluation, normalized_evaluation)
      {:noreply, assign(socket, :game, updated_game)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("client_eval_error", %{"error" => _error}, socket) do
    # Evaluation failed, keep server-side evaluation
    {:noreply, socket}
  end

  def handle_event("robot_move_ready", %{"move" => move}, socket) do
    # Client has calculated the best move for the robot
    room_id = socket.assigns.room_id

    case LiveChess.GameServer.robot_move(room_id, move) do
      {:ok, _state} -> {:noreply, socket}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("robot_move_error", %{"error" => _error}, socket) do
    # Robot move calculation failed
    {:noreply, socket}
  end

  def handle_event("select_square", %{"square" => square}, socket) do
    cond do
      not viewing_live?(socket) ->
        {:noreply, socket}

      not active_player?(socket) ->
        {:noreply, socket}

      socket.assigns.selected_square == nil ->
        handle_first_selection(square, socket)

      socket.assigns.selected_square == square ->
        {:noreply,
         socket
         |> assign(:selected_square, nil)
         |> assign(:available_moves, MapSet.new())}

      piece_for(socket.assigns.game, square) |> owns_piece?(socket.assigns.role) ->
        moves = fetch_moves(socket, square)

        {:noreply,
         socket
         |> assign(:selected_square, square)
         |> assign(:available_moves, MapSet.new(moves))}

      true ->
        attempt_move(socket, socket.assigns.selected_square, square)
    end
  end

  @impl true
  def handle_info({:game_state, state}, socket) do
    previous_game = socket.assigns.game
    new_status = Map.get(state, :status)

    socket =
      socket
      |> maybe_play_join_sound(previous_game, state)
      |> maybe_play_move_sound(previous_game, state)
      |> set_game_state(state)
      |> assign(:error_message, nil)
      |> maybe_reset_selection(state)
      |> request_client_evaluation(state)
      |> maybe_request_robot_move(state)

    # Set or preserve definitive evaluation for finished games
    socket =
      if finished_status?(new_status) do
        set_final_evaluation_if_finished(socket, state)
      else
        socket
      end

    {:noreply, maybe_auto_join(socket, state)}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    # Update spectator count when presence changes
    topic = socket.assigns[:presence_topic] || "game:#{socket.assigns.room_id}"
    {:noreply, update_spectator_count_from_presence(socket, topic)}
  end

  @impl true
  def terminate(_reason, socket) do
    Games.leave(socket.assigns.room_id, socket.assigns.player_token)
    :ok
  end

  defp handle_first_selection(square, socket) do
    case piece_for(socket.assigns.game, square) do
      %{color: color} when color == socket.assigns.role ->
        moves = fetch_moves(socket, square)

        {:noreply,
         socket
         |> assign(:selected_square, square)
         |> assign(:available_moves, MapSet.new(moves))}

      _ ->
        {:noreply, socket}
    end
  end

  defp attempt_move(socket, from, to) do
    case Games.make_move(socket.assigns.room_id, socket.assigns.player_token, from, to) do
      {:ok, %{state: state}} ->
        {:noreply,
         socket
         |> set_game_state(state)
         |> assign(:selected_square, nil)
         |> assign(:available_moves, MapSet.new())
         |> assign(:error_message, nil)
         |> push_event("vibrate-move", %{})}

      {:error, :not_your_turn} ->
        {:noreply, assign(socket, :error_message, "It's not your turn.")}

      {:error, :invalid_square} ->
        {:noreply, assign(socket, :error_message, "Select a valid destination square.")}

      {:error, :game_not_active} ->
        {:noreply,
         assign(socket, :error_message, "Waiting for both players before moves can be made.")}

      {:error, :not_authorized} ->
        {:noreply, assign(socket, :error_message, "Only players can make moves.")}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :error_message, message)}

      {:error, _} ->
        {:noreply, assign(socket, :error_message, "That move is not allowed.")}
    end
  end

  defp maybe_reset_selection(socket, state) do
    cond do
      socket.assigns.selected_square == nil ->
        socket

      piece_for(state, socket.assigns.selected_square) == nil ->
        socket
        |> assign(:selected_square, nil)
        |> assign(:available_moves, MapSet.new())

      true ->
        socket
    end
  end

  defp piece_for(nil, _square), do: nil

  defp piece_for(%{board: board}, square) do
    board
    |> List.flatten()
    |> Enum.find_value(fn cell -> if cell.id == square, do: cell.piece end)
  end

  defp owns_piece?(nil, _role), do: false
  defp owns_piece?(%{color: color}, role), do: color == role

  defp active_player?(socket) do
    socket.assigns.role in [:white, :black] and
      match?(%{status: status} when status in [:active, :playing], socket.assigns.game)
  end

  defp build_share_url(room_id), do: to_string(url(~p"/game/#{room_id}"))

  defp set_game_state(socket, state) when is_map(state) do
    previous_game = socket.assigns[:game]
    previous_cursor = socket.assigns[:history_cursor]
    previous_length = socket.assigns[:history_length] || 0
    new_length = history_length(state)

    desired_cursor =
      cond do
        is_nil(previous_cursor) -> nil
        previous_cursor >= previous_length -> new_length
        true -> previous_cursor
      end

    history = history_assignments(state, desired_cursor)

    active_last_move =
      cond do
        history.length == 0 -> nil
        history.cursor == history.length -> Map.get(state, :last_move)
        true -> history.move_override
      end

    socket
    |> assign(:game, state)
    |> assign(:history_cursor, history.cursor)
    |> assign(:history_length, history.length)
    |> assign(:board_override, history.board_override)
    |> assign(:active_last_move, active_last_move)
    |> assign(:history_status, history.caption)
    |> assign(:history_entries, history.entries)
    |> assign(:history_pairs, history.pairs)
    |> assign(:history_selected_ply, history.selected_ply)
    |> maybe_reset_endgame_overlay(previous_game, state)
  end

  defp set_game_state(socket, _state), do: socket

  defp set_final_evaluation_if_finished(socket, state) do
    # Only set definitive evaluation if game is finished and has a winner
    if finished_status?(Map.get(state, :status)) do
      winner = Map.get(state, :winner)

      if winner in [:white, :black] do
        # Create definitive evaluation showing the winner has 100% advantage
        final_evaluation = %{
          "score_cp" => if(winner == :white, do: 10_000, else: -10_000),
          "display_score" => if(winner == :white, do: "+♔", else: "−♔"),
          "white_percentage" => if(winner == :white, do: 100.0, else: 0.0),
          "advantage" => Atom.to_string(winner),
          "source" => "game_result"
        }

        game = socket.assigns.game

        if game do
          updated_game = Map.put(game, :evaluation, final_evaluation)
          assign(socket, :game, updated_game)
        else
          socket
        end
      else
        socket
      end
    else
      socket
    end
  end

  defp update_history_cursor(socket, desired_cursor) do
    history = history_assignments(socket.assigns.game, desired_cursor)

    base_game = socket.assigns.game || %{}

    active_last_move =
      cond do
        history.length == 0 -> nil
        history.cursor == history.length -> Map.get(base_game, :last_move)
        true -> history.move_override
      end

    socket
    |> assign(:history_cursor, history.cursor)
    |> assign(:history_length, history.length)
    |> assign(:board_override, history.board_override)
    |> assign(:active_last_move, active_last_move)
    |> assign(:history_status, history.caption)
    |> assign(:history_entries, history.entries)
    |> assign(:history_pairs, history.pairs)
    |> assign(:history_selected_ply, history.selected_ply)
    |> assign(:selected_square, nil)
    |> assign(:available_moves, MapSet.new())
  end

  defp history_assignments(nil, _desired_cursor) do
    %{
      cursor: 0,
      length: 0,
      board_override: nil,
      move_override: nil,
      caption: "No moves yet.",
      entries: [],
      pairs: [],
      selected_ply: nil
    }
  end

  defp history_assignments(game, desired_cursor) when is_map(game) do
    entries = history_moves(game)
    length = length(entries)
    cursor = clamp_cursor(desired_cursor, length)
    {board_override, move_override} = history_board_override(game, cursor, length)
    caption = history_caption(game, cursor, length)

    %{
      cursor: cursor,
      length: length,
      board_override: board_override,
      move_override: move_override,
      caption: caption,
      entries: entries,
      pairs: history_pairs(entries),
      selected_ply: if(cursor > 0, do: cursor, else: nil)
    }
  end

  defp history_length(%{history_moves: moves}) when is_list(moves), do: length(moves)
  defp history_length(%{timeline: timeline}) when is_list(timeline), do: length(timeline)
  defp history_length(_), do: 0

  defp clamp_cursor(value, length) when is_integer(value), do: value |> max(0) |> min(length)
  defp clamp_cursor(_value, length), do: length

  defp history_board_override(game, cursor, length) do
    timeline = Map.get(game, :timeline, [])

    cond do
      length == 0 ->
        {nil, nil}

      cursor == length ->
        {nil, nil}

      cursor == 0 ->
        {board_from_fen(Map.get(game, :initial_fen)), nil}

      true ->
        case Enum.at(timeline, cursor - 1) do
          %{after_fen: after_fen, move: move} ->
            {board_from_fen(after_fen), parse_move_string(move)}

          _ ->
            {nil, nil}
        end
    end
  end

  defp board_from_fen(nil), do: nil

  defp board_from_fen(fen) when is_binary(fen) do
    ChessGame.new(fen)
    |> Board.from_game()
  rescue
    _ -> nil
  end

  defp board_from_fen(_), do: nil

  defp parse_move_string(move) when is_binary(move) do
    case String.split(move, "-", parts: 2) do
      [from, to_part] ->
        to = String.slice(to_part, 0, 2)

        if byte_size(from) == 2 and byte_size(to) == 2 do
          %{
            from: String.downcase(from),
            to: String.downcase(to)
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp parse_move_string(_), do: nil

  defp history_caption(_game, _cursor, 0), do: "No moves yet."
  defp history_caption(_game, 0, _length), do: "Starting position"

  defp history_caption(_game, cursor, length) when cursor == length do
    if length == 0, do: "No moves yet.", else: "Live position"
  end

  defp history_caption(game, cursor, _length) do
    moves = history_moves(game)

    case Enum.at(moves, cursor - 1) do
      %{san: san} = move -> "After #{move_prefix(move, cursor)}#{san}"
      _ -> "After move #{cursor}"
    end
  end

  defp history_moves(%{history_moves: moves}) when is_list(moves) do
    Enum.map(moves, &normalize_history_move/1)
  end

  defp history_moves(%{timeline: timeline}) when is_list(timeline) do
    timeline
    |> Notation.annotate()
    |> Enum.map(&normalize_history_move/1)
  end

  defp history_moves(_), do: []

  defp history_pairs(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {entry, idx}, acc ->
      color = entry_color(entry, idx)
      entry = %{entry | color: color}
      number = move_number(entry, idx)

      case color do
        :white ->
          [%{number: number, white: entry, black: nil} | acc]

        :black ->
          case acc do
            [%{number: ^number} = pair | rest] ->
              [%{pair | black: entry} | rest]

            _ ->
              [%{number: number, white: nil, black: entry} | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_history_move(move) when is_map(move) do
    ply = Map.get(move, :ply) || Map.get(move, "ply")
    san = Map.get(move, :san) || Map.get(move, "san") || Map.get(move, :move) || ""
    from = Map.get(move, :from) || Map.get(move, "from")
    to = Map.get(move, :to) || Map.get(move, "to")
    raw_color = Map.get(move, :color) || Map.get(move, "color")
    color = normalize_move_color(raw_color, ply)

    %{
      ply: ply,
      san: san,
      move: Map.get(move, :move) || Map.get(move, "move"),
      from: from,
      to: to,
      color: color
    }
  end

  defp normalize_history_move(_),
    do: %{san: "", color: :white, ply: nil, move: nil, from: nil, to: nil}

  defp normalize_move_color(color, _ply) when color in [:white, :black], do: color
  defp normalize_move_color("white", _), do: :white
  defp normalize_move_color("black", _), do: :black

  defp normalize_move_color(_, ply) when is_integer(ply),
    do: if(rem(ply, 2) == 1, do: :white, else: :black)

  defp normalize_move_color(_, _), do: :white

  defp entry_color(%{color: color}, _) when color in [:white, :black], do: color
  defp entry_color(%{ply: ply}, _) when is_integer(ply), do: normalize_move_color(nil, ply)
  defp entry_color(_, idx), do: if(rem(idx, 2) == 1, do: :white, else: :black)

  defp move_number(%{ply: ply}, _) when is_integer(ply), do: div(ply + 1, 2)
  defp move_number(_entry, idx), do: div(idx + 1, 2)

  defp move_prefix(move, cursor) do
    number = move_number(move, cursor)

    case entry_color(move, cursor) do
      :black -> "#{number}... "
      _ -> "#{number}. "
    end
  end

  defp move_cell_classes(nil, _selected_ply) do
    "moves-cell rounded-md px-2 py-1 text-sm font-medium text-slate-400 dark:text-slate-500"
  end

  defp move_cell_classes(%{ply: ply}, selected_ply)
       when is_integer(ply) and is_integer(selected_ply) and ply == selected_ply do
    "moves-cell rounded-md px-2 py-1 text-sm font-semibold text-emerald-700 bg-emerald-100 dark:bg-emerald-900/60 dark:text-emerald-100"
  end

  defp move_cell_classes(_move, _selected_ply) do
    "moves-cell rounded-md px-2 py-1 text-sm font-medium text-slate-700 dark:text-slate-200"
  end

  defp move_display(nil), do: "—"

  defp move_display(%{san: san}) when is_binary(san) and san != "" do
    san
  end

  defp move_display(%{move: move}) when is_binary(move) do
    move
  end

  defp move_display(_), do: "—"

  defp move_aria_current(%{ply: ply}, selected_ply)
       when is_integer(ply) and is_integer(selected_ply) and ply == selected_ply,
       do: "step"

  defp move_aria_current(_move, _selected_ply), do: nil

  defp board_rows(_game, role, board_override) when is_list(board_override),
    do: Board.oriented(board_override, role)

  defp board_rows(%{board: board}, role, _board_override) when is_list(board),
    do: Board.oriented(board, role)

  defp board_rows(_game, _role, _board_override), do: []

  defp viewing_live?(%{assigns: assigns}) do
    viewing_live?(Map.get(assigns, :history_cursor, 0), Map.get(assigns, :history_length, 0))
  end

  defp viewing_live?(cursor, length) when is_integer(cursor) and is_integer(length),
    do: cursor >= length

  defp viewing_live?(_cursor, _length), do: true

  defp maybe_reset_endgame_overlay(socket, previous_game, new_game) do
    prev_status = previous_game && Map.get(previous_game, :status)
    new_status = Map.get(new_game, :status)

    cond do
      finished_status?(new_status) and new_status != prev_status ->
        assign(socket, :endgame_overlay_dismissed, false)

      finished_status?(new_status) ->
        socket

      true ->
        assign(socket, :endgame_overlay_dismissed, false)
    end
  end

  defp overlay_active?(%{assigns: assigns}) do
    dismissed? = Map.get(assigns, :endgame_overlay_dismissed, false)

    if dismissed? do
      false
    else
      game = Map.get(assigns, :game)
      role = Map.get(assigns, :role)
      not is_nil(build_endgame_overlay(game, role))
    end
  end

  defp overlay_active?(_socket), do: false

  defp maybe_auto_join(socket, state) do
    seat = available_seat(state)

    cond do
      socket.assigns.role in [:white, :black] ->
        reset_auto_join(socket)

      seat ->
        attempt = auto_join_attempt(socket.assigns)
        now = System.monotonic_time(:millisecond)

        if recently_attempted?(attempt, seat, now) do
          socket
        else
          case Games.join_game(socket.assigns.room_id, socket.assigns.player_token) do
            {:ok, %{role: role, state: new_state}} ->
              socket
              |> assign(:role, role)
              |> set_game_state(new_state)
              |> assign(:error_message, nil)
              |> reset_auto_join()

            {:error, :slot_taken} ->
              reset_auto_join(socket)

            {:error, _} ->
              socket
              |> assign(:auto_join_attempt, %{target: seat, attempted_at: now})
          end
        end

      true ->
        reset_auto_join(socket)
    end
  end

  defp available_seat(%{players: %{white: nil, black: nil}}), do: Enum.random([:white, :black])

  defp available_seat(%{players: %{white: nil}}), do: :white
  defp available_seat(%{players: %{black: nil}}), do: :black
  defp available_seat(_), do: nil

  defp auto_join_attempt(assigns) do
    Map.get(assigns, :auto_join_attempt, %{target: nil, attempted_at: nil})
  end

  defp reset_auto_join(socket) do
    assign(socket, :auto_join_attempt, %{target: nil, attempted_at: nil})
  end

  defp recently_attempted?(%{target: target, attempted_at: attempted_at}, seat, now) do
    target == seat && attempted_at && now - attempted_at < @auto_join_retry_ms
  end

  defp recently_attempted?(_attempt, _seat, _now), do: false

  defp determine_initial_role(state, token, fallback) do
    infer_role_from_state(state, token) || available_seat(state) || fallback
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="game-surface"
      phx-hook="SoundEffects"
      phx-window-keydown="escape_press"
      phx-key="escape"
      class="mx-auto max-w-6xl px-2 py-4 sm:px-4 sm:py-8"
    >
      <div
        id="stockfish-evaluator"
        phx-hook="StockfishEvaluator"
        data-stockfish-path="/assets/stockfish-17.1-lite-single-03e3232.js"
        style="display: none;"
      >
      </div>
      <div class="flex flex-col gap-4 sm:gap-6 lg:flex-row">
        <div class="flex-1">
          <%= if @board_ready? and @game do %>
            <div class="chess-board-panel">
              <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <div class="flex flex-wrap items-center gap-3">
                  <h2 class="text-lg font-semibold text-slate-900 dark:text-slate-100">
                    Room {@room_id}
                  </h2>
                  <button
                    type="button"
                    phx-click="request_home"
                    class="inline-flex items-center gap-2 rounded-full border border-slate-300 px-3 py-1 text-sm font-medium text-slate-700 transition hover:bg-slate-100 focus:outline-none focus:ring-2 focus:ring-slate-400 focus:ring-offset-2 dark:border-slate-600 dark:text-slate-200 dark:hover:bg-slate-800 dark:focus:ring-slate-500"
                  >
                    <span class="hidden sm:inline">Back to lobby</span>
                    <span class="sm:hidden">Lobby</span>
                  </button>
                  <%= if show_surrender_button?(@role, @game) do %>
                    <button
                      type="button"
                      phx-click="request_surrender"
                      class="inline-flex items-center gap-2 rounded-full border border-rose-300 px-3 py-1 text-sm font-medium text-rose-600 transition hover:bg-rose-50 focus:outline-none focus:ring-2 focus:ring-rose-400 focus:ring-offset-2 dark:border-rose-500/60 dark:text-rose-200 dark:hover:bg-rose-900/30 dark:focus:ring-rose-400/70"
                    >
                      Surrender
                    </button>
                  <% end %>
                </div>
                <.turn_indicator game={@game} player_token={@player_token} />
              </div>
              <div class="mt-2 flex flex-wrap items-baseline gap-x-2 gap-y-1">
                <span class={"text-sm " <> status_classes(@game)}>{status_line(@game)}</span>
              </div>

              <div class="chess-board-grid" phx-hook="ChessBoard" id="chess-board">
                <%= for row <- board_rows(@game, @role, @board_override) do %>
                  <%= for cell <- row do %>
                    <button
                      type="button"
                      phx-click="select_square"
                      phx-value-square={cell.id}
                      class={
                        square_classes(
                          @role,
                          cell,
                          @selected_square,
                          @active_last_move,
                          @available_moves,
                          viewing_live?(@history_cursor, @history_length)
                        )
                      }
                    >
                      <div class="piece-wrapper">
                        {piece_svg(cell.piece)}
                      </div>
                      <%= if show_move_dot?(@available_moves, cell, @role) do %>
                        <span class="pointer-events-none absolute inset-0 flex items-center justify-center">
                          <span class="move-dot"></span>
                        </span>
                      <% end %>
                      <span class="sr-only">{cell.id}</span>
                    </button>
                  <% end %>
                <% end %>
              </div>
            </div>
          <% else %>
            <div class="rounded-md border border-amber-300 bg-amber-50 p-4 text-amber-900 dark:border-amber-400 dark:bg-amber-900/40 dark:text-amber-200">
              Preparing game state...
            </div>
          <% end %>
        </div>

        <div class="panel-surface">
          <h3 class="text-lg font-semibold text-slate-800 dark:text-slate-100">Advantage</h3>
          <.evaluation_panel evaluation={@game && Map.get(@game, :evaluation)} role={@role} />
        </div>
        <div class="panel-surface">
          <div class="flex items-center justify-between gap-3">
            <h3 class="text-lg font-semibold text-slate-800 dark:text-slate-100">Players</h3>
            <span
              class={viewer_count_badge_classes(@game, @role)}
              aria-label={"#{viewer_count_label(@game, @role)} watching"}
            >
              <span aria-hidden="true">👀</span>
              {viewer_count_label(@game, @role)}
            </span>
          </div>
          <div class="mt-3 space-y-2 text-sm text-slate-700 dark:text-slate-300">
            <.player_line game={@game} color={:white} token={@player_token} />
            <.player_line game={@game} color={:black} token={@player_token} />
          </div>
        </div>
        <div class="w-full space-y-4 lg:max-w-sm">
          <div class="panel-surface">
            <h3 class="text-lg font-semibold text-slate-800 dark:text-slate-100">Share</h3>
            <p class="mt-1 text-sm text-slate-600 dark:text-slate-300">
              Send this link to a friend so they can join.
            </p>
            <div
              id={"share-link-#{@room_id}"}
              class="mt-3"
              phx-hook="CopyShareLink"
              data-url={@share_url}
              data-success-text="Link copied to clipboard"
            >
              <input
                type="text"
                readonly
                value={@share_url}
                class="w-full cursor-pointer select-none rounded-md border border-slate-300 bg-slate-100 px-3 py-2 text-sm text-slate-700 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-200"
                data-share-input
              />
              <p
                class="mt-2 hidden text-sm text-emerald-600 dark:text-emerald-400"
                data-copy-message
                role="status"
                aria-live="polite"
              >
              </p>
              <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
                Room code: <span class="font-mono uppercase">{@room_id}</span>
              </p>
            </div>
          </div>

          <div class="panel-surface">
            <div class="flex items-center justify-between">
              <h3 class="text-lg font-semibold text-slate-800 dark:text-slate-100">Moves</h3>
              <div class="flex items-center gap-2">
                <.history_nav_button
                  event="history_prev"
                  label="‹"
                  disabled={history_prev_disabled?(@history_cursor, @history_length)}
                />
                <.history_nav_button
                  event="history_next"
                  label="›"
                  disabled={history_next_disabled?(@history_cursor, @history_length)}
                />
                <button
                  type="button"
                  phx-click="history_live"
                  class={live_button_classes(@history_cursor, @history_length)}
                >
                  Live
                </button>
              </div>
            </div>
            <p class="mt-2 text-xs font-medium text-slate-500 dark:text-slate-400">
              {@history_status}
              <%= if @history_length > 0 do %>
                <span class="ml-2 font-semibold text-slate-600 dark:text-slate-300">
                  ({@history_cursor || @history_length}/{@history_length})
                </span>
              <% end %>
            </p>
            <div class="moves-table">
              <div class="moves-table-header">
                <span>Move</span>
                <span>White</span>
                <span>Black</span>
              </div>
              <div class="moves-table-body">
                <%= if @history_pairs != [] do %>
                  <%= for pair <- @history_pairs do %>
                    <div class="moves-table-row">
                      <span class="moves-table-index">{pair.number}.</span>
                      <span
                        class={move_cell_classes(pair.white, @history_selected_ply)}
                        aria-current={move_aria_current(pair.white, @history_selected_ply)}
                      >
                        {move_display(pair.white)}
                      </span>
                      <span
                        class={move_cell_classes(pair.black, @history_selected_ply)}
                        aria-current={move_aria_current(pair.black, @history_selected_ply)}
                      >
                        {move_display(pair.black)}
                      </span>
                    </div>
                  <% end %>
                <% else %>
                  <div class="px-4 py-6 text-center text-sm text-slate-400 dark:text-slate-500">
                    No moves yet.
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <%= if @error_message do %>
            <div class="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-700 dark:border-red-500/60 dark:bg-red-900/40 dark:text-red-200">
              {@error_message}
            </div>
          <% end %>
        </div>
      </div>
      <%= if not @endgame_overlay_dismissed do %>
        <%= if overlay = build_endgame_overlay(@game, @role) do %>
          <.endgame_overlay overlay={overlay} />
        <% end %>
      <% end %>
      <%= if @show_leave_modal do %>
        <div class="fixed inset-0 z-40 flex items-center justify-center bg-slate-950/50 backdrop-blur-sm">
          <div
            phx-click="cancel_leave"
            class="absolute inset-0 h-full w-full"
            aria-hidden="true"
          >
          </div>
          <div
            class="relative z-10 w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-xl dark:border-slate-700 dark:bg-slate-900"
            role="dialog"
            aria-modal="true"
            aria-labelledby="leave-game-title"
          >
            <h2 id="leave-game-title" class="text-lg font-semibold text-slate-900 dark:text-slate-100">
              Leave game?
            </h2>
            <p class="mt-2 text-sm text-slate-600 dark:text-slate-300">
              The game is still in progress. Leaving now will return you to the lobby and keep your seat active for a few minutes.
            </p>
            <div class="mt-6 flex justify-end gap-3">
              <button
                type="button"
                phx-click="cancel_leave"
                class="inline-flex items-center rounded-md border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 transition hover:bg-slate-100 focus:outline-none focus:ring-2 focus:ring-slate-400 focus:ring-offset-2 dark:border-slate-600 dark:text-slate-200 dark:hover:bg-slate-800 dark:focus:ring-slate-500"
              >
                Stay
              </button>
              <button
                type="button"
                phx-click="confirm_leave"
                class="inline-flex items-center rounded-md bg-rose-600 px-4 py-2 text-sm font-semibold text-white transition hover:bg-rose-500 focus:outline-none focus:ring-2 focus:ring-rose-400 focus:ring-offset-2 disabled:opacity-60"
              >
                Leave game
              </button>
            </div>
          </div>
        </div>
      <% end %>
      <%= if @show_surrender_modal do %>
        <div class="fixed inset-0 z-40 flex items-center justify-center bg-slate-950/50 backdrop-blur-sm">
          <div
            phx-click="cancel_surrender"
            class="absolute inset-0 h-full w-full"
            aria-hidden="true"
          >
          </div>
          <div
            class="relative z-10 w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-xl dark:border-slate-700 dark:bg-slate-900"
            role="dialog"
            aria-modal="true"
            aria-labelledby="surrender-game-title"
          >
            <h2
              id="surrender-game-title"
              class="text-lg font-semibold text-slate-900 dark:text-slate-100"
            >
              Surrender game?
            </h2>
            <p class="mt-2 text-sm text-slate-600 dark:text-slate-300">
              This will immediately resign and award the win to your opponent. You cannot undo this action.
            </p>
            <div class="mt-6 flex justify-end gap-3">
              <button
                type="button"
                phx-click="cancel_surrender"
                class="inline-flex items-center rounded-md border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 transition hover:bg-slate-100 focus:outline-none focus:ring-2 focus:ring-slate-400 focus:ring-offset-2 dark:border-slate-600 dark:text-slate-200 dark:hover:bg-slate-800 dark:focus:ring-slate-500"
              >
                Keep playing
              </button>
              <button
                type="button"
                phx-click="confirm_surrender"
                class="inline-flex items-center rounded-md bg-rose-600 px-4 py-2 text-sm font-semibold text-white transition hover:bg-rose-500 focus:outline-none focus:ring-2 focus:ring-rose-400 focus:ring-offset-2 disabled:opacity-60"
              >
                Confirm surrender
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :overlay, :map, required: true

  def endgame_overlay(assigns) do
    overlay = assigns.overlay

    assigns =
      assigns
      |> assign(:overlay_class, overlay_class(Map.get(overlay, :type)))
      |> assign(:overlay_type, Map.get(overlay, :type))
      |> assign(:heading, Map.get(overlay, :heading, ""))
      |> assign(:subtext, Map.get(overlay, :subtext))
      |> assign(:cta_label, Map.get(overlay, :cta_label, "Continue"))

    ~H"""
    <div
      class={"endgame-overlay " <> @overlay_class}
      role="dialog"
      aria-modal="true"
      aria-live="assertive"
      phx-click="dismiss_endgame_overlay"
      phx-hook="EndgameCanvas"
      id="endgame-overlay"
      data-overlay-type={@overlay_type}
    >
      <div class="endgame-overlay__content" phx-click="noop" phx-stop>
        <p class="endgame-overlay__heading">{@heading}</p>
        <%= if @subtext do %>
          <p class="endgame-overlay__subtext">{@subtext}</p>
        <% end %>
        <button
          type="button"
          class="endgame-overlay__cta"
          phx-click="dismiss_endgame_overlay"
        >
          {@cta_label}
        </button>
      </div>
    </div>
    """
  end

  attr :evaluation, :any, default: nil
  attr :role, :atom, default: :white

  def evaluation_panel(%{evaluation: nil} = assigns) do
    ~H"""
    <div class="mt-2 flex h-20 items-center justify-center">
      <div class="h-3/5 w-full max-w-xs animate-pulse rounded-full bg-slate-200 dark:bg-slate-700" />
    </div>
    """
  end

  def evaluation_panel(assigns) do
    # Ensure white_pct is a float for arithmetic operations
    # Handle both atom keys (from server) and string keys (from JavaScript)
    white_pct =
      case assigns.evaluation[:white_percentage] || assigns.evaluation["white_percentage"] do
        nil -> 50.0
        val when is_number(val) -> val * 1.0
        val when is_binary(val) -> String.to_float(val)
      end

    black_pct = max(0.0, 100.0 - white_pct)

    # When playing as black, flip the perspective
    {player_pct, opponent_pct, player_label, opponent_label} =
      if assigns.role == :black do
        {black_pct, white_pct, "Black", "White"}
      else
        {white_pct, black_pct, "White", "Black"}
      end

    # Flip evaluation for Black players to show from their perspective
    # Frontend always sends from White's perspective (positive = White better)
    # For Black players, we flip it so positive = Black better (you're better)
    evaluation =
      if assigns.role == :black do
        flip_evaluation_for_black(assigns.evaluation)
      else
        assigns.evaluation
      end

    assigns =
      assigns
      |> assign(:white_pct, white_pct)
      |> assign(:player_pct, player_pct)
      |> assign(:opponent_pct, opponent_pct)
      |> assign(:player_label, player_label)
      |> assign(:opponent_label, opponent_label)
      |> assign(:player_pct_display, format_percentage(player_pct))
      |> assign(:opponent_pct_display, format_percentage(opponent_pct))
      |> assign(:evaluation, evaluation)

    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
        <span class="text-left text-slate-700 dark:text-slate-200">
          {@player_label} {@player_pct_display}%
        </span>
        <span class={"text-xs font-semibold " <> score_text_class(@evaluation, @role)}>
          {evaluation_indicator(@evaluation, @role)}
        </span>
        <span class="text-right text-slate-700 dark:text-slate-200">
          {@opponent_label} {@opponent_pct_display}%
        </span>
      </div>
      <div class="relative h-4 w-full overflow-hidden rounded-full border border-slate-300 bg-slate-900 shadow-inner dark:border-slate-600 dark:bg-slate-800">
        <div
          class="absolute inset-y-0 left-0 bg-emerald-400 transition-all duration-500 ease-in-out dark:bg-emerald-500/80"
          style={"width: #{@player_pct}%"}
        />
      </div>
      <p class="text-center text-xs text-slate-600 dark:text-slate-400">
        {evaluation_caption(@evaluation, @role)}
      </p>
    </div>
    """
  end

  # Flip evaluation from White's perspective to Black's perspective
  # Frontend sends: positive score = White better, advantage = "white"
  # For Black player: we only flip the score sign, NOT the advantage
  # The advantage still shows who is actually winning
  defp flip_evaluation_for_black(nil), do: nil

  defp flip_evaluation_for_black(evaluation) when is_map(evaluation) do
    # DON'T flip advantage - it should still show who is actually winning
    # We only flip the display score sign so Black sees positive = good for them

    # Flip display score sign: + becomes -, - becomes +
    # So positive scores mean "good for you" for both White and Black players
    evaluation =
      cond do
        Map.has_key?(evaluation, "display_score") ->
          new_score = flip_score_sign(evaluation["display_score"])
          Map.put(evaluation, "display_score", new_score)

        Map.has_key?(evaluation, :display_score) ->
          new_score = flip_score_sign(evaluation[:display_score])
          Map.put(evaluation, :display_score, new_score)

        true ->
          evaluation
      end

    evaluation
  end

  defp flip_score_sign(nil), do: nil

  defp flip_score_sign(score) when is_binary(score) do
    cond do
      String.starts_with?(score, "+M") ->
        "-M" <> String.slice(score, 2..-1//1)

      String.starts_with?(score, "-M") ->
        "+M" <> String.slice(score, 2..-1//1)

      String.starts_with?(score, "+") ->
        "-" <> String.slice(score, 1..-1//1)

      String.starts_with?(score, "-") ->
        "+" <> String.slice(score, 1..-1//1)

      true ->
        score
    end
  end

  defp flip_score_sign(score), do: score

  # Handle both atom keys (server-side) and string keys (client-side)
  # After flipping for Black, advantage matching player color = player is winning
  defp evaluation_caption(%{"advantage" => "white", "display_score" => score}, :white),
    do: append_score("You are better", score)

  defp evaluation_caption(%{"advantage" => "black", "display_score" => score}, :white),
    do: append_score("Opponent is better", score)

  defp evaluation_caption(%{advantage: :white, display_score: score}, :white),
    do: append_score("You are better", score)

  defp evaluation_caption(%{advantage: :black, display_score: score}, :white),
    do: append_score("Opponent is better", score)

  defp evaluation_caption(%{"advantage" => "black", "display_score" => score}, :black),
    do: append_score("You are better", score)

  defp evaluation_caption(%{"advantage" => "white", "display_score" => score}, :black),
    do: append_score("Opponent is better", score)

  defp evaluation_caption(%{advantage: :black, display_score: score}, :black),
    do: append_score("You are better", score)

  defp evaluation_caption(%{advantage: :white, display_score: score}, :black),
    do: append_score("Opponent is better", score)

  # Spectators see neutral language
  defp evaluation_caption(%{"advantage" => "white", "display_score" => score}, _role),
    do: append_score("White is better", score)

  defp evaluation_caption(%{advantage: :white, display_score: score}, _role),
    do: append_score("White is better", score)

  defp evaluation_caption(%{"advantage" => "black", "display_score" => score}, _role),
    do: append_score("Black is better", score)

  defp evaluation_caption(%{advantage: :black, display_score: score}, _role),
    do: append_score("Black is better", score)

  defp evaluation_caption(%{"display_score" => score}, _role),
    do: append_score("Even position", score)

  defp evaluation_caption(%{display_score: score}, _role),
    do: append_score("Even position", score)

  defp evaluation_caption(_, _), do: "Evaluating..."

  defp format_percentage(value) when is_integer(value) do
    (value / 1.0)
    |> Float.round(1)
    |> :erlang.float_to_binary([{:decimals, 1}])
  end

  defp format_percentage(value) when is_float(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary([{:decimals, 1}])
  end

  defp format_percentage(_), do: "0.0"

  # Score text class - show green when player has advantage, red when opponent has advantage
  # After flipping score (but not advantage), advantage still shows who is actually winning
  defp score_text_class(%{"advantage" => "white"}, :white), do: "text-emerald-500"
  defp score_text_class(%{advantage: :white}, :white), do: "text-emerald-500"
  defp score_text_class(%{"advantage" => "black"}, :black), do: "text-emerald-500"
  defp score_text_class(%{advantage: :black}, :black), do: "text-emerald-500"

  # When opponent has advantage, show red
  defp score_text_class(%{"advantage" => "black"}, :white), do: "text-rose-500"
  defp score_text_class(%{advantage: :black}, :white), do: "text-rose-500"
  defp score_text_class(%{"advantage" => "white"}, :black), do: "text-rose-500"
  defp score_text_class(%{advantage: :white}, :black), do: "text-rose-500"

  # For spectators, show advantage color for whoever is winning
  defp score_text_class(%{"advantage" => adv}, _) when adv in ["white", "black"],
    do: "text-emerald-500"

  defp score_text_class(%{advantage: adv}, _) when adv in [:white, :black], do: "text-emerald-500"
  defp score_text_class(_, _), do: "text-slate-500 dark:text-slate-300"

  # Evaluation indicator - show "Your edge" when advantage matches player's color
  # Advantage is NOT flipped, so it shows who is actually winning
  defp evaluation_indicator(%{"advantage" => "white"}, :white), do: "Your edge"
  defp evaluation_indicator(%{advantage: :white}, :white), do: "Your edge"
  defp evaluation_indicator(%{"advantage" => "black"}, :black), do: "Your edge"
  defp evaluation_indicator(%{advantage: :black}, :black), do: "Your edge"

  defp evaluation_indicator(%{"advantage" => "white"}, :black), do: "Opponent edge"
  defp evaluation_indicator(%{advantage: :white}, :black), do: "Opponent edge"
  defp evaluation_indicator(%{"advantage" => "black"}, :white), do: "Opponent edge"
  defp evaluation_indicator(%{advantage: :black}, :white), do: "Opponent edge"

  # For spectators, show which color has advantage
  defp evaluation_indicator(%{"advantage" => "white"}, _), do: "White edge"
  defp evaluation_indicator(%{advantage: :white}, _), do: "White edge"
  defp evaluation_indicator(%{"advantage" => "black"}, _), do: "Black edge"
  defp evaluation_indicator(%{advantage: :black}, _), do: "Black edge"

  defp evaluation_indicator(_, _), do: "Balanced"

  defp append_score(label, score) when is_binary(score) do
    trimmed = String.trim(score)

    if trimmed in ["", "0", "0.0", "0.00", "+0.00", "-0.00"] do
      label
    else
      "#{label} (#{trimmed})"
    end
  end

  defp append_score(label, _score), do: label

  defp build_endgame_overlay(_game, role) when role not in [:white, :black], do: nil
  defp build_endgame_overlay(nil, _role), do: nil

  defp build_endgame_overlay(%{status: status} = game, role) do
    winner = Map.get(game, :winner)

    cond do
      not finished_status?(status) ->
        nil

      winner not in [:white, :black] ->
        nil

      true ->
        players = Map.get(game, :players, %{})
        opponent_color = opposite_color(role)
        opponent = Map.get(players, opponent_color)

        cond do
          winner == role ->
            {heading, subtext} = winner_overlay_copy(status, opponent, opponent_color)

            %{
              type: :celebration,
              heading: heading,
              subtext: subtext
            }

          winner == opponent_color ->
            winner_player = Map.get(players, winner)
            {heading, subtext} = loser_overlay_copy(status, winner_player, winner)

            %{
              type: :defeat,
              heading: heading,
              subtext: subtext
            }

          true ->
            nil
        end
    end
  end

  defp winner_overlay_copy(:completed, opponent, opponent_color) do
    {
      "Checkmate! 🎉",
      "You defeated #{overlay_player_display(opponent, opponent_color)}."
    }
  end

  defp winner_overlay_copy(:resigned, opponent, opponent_color) do
    opponent_display = capitalize_phrase(overlay_player_display(opponent, opponent_color))

    {
      "Victory by resignation",
      "#{opponent_display} resigned. You take the win."
    }
  end

  defp winner_overlay_copy(_status, opponent, opponent_color) do
    opponent_display = capitalize_phrase(overlay_player_display(opponent, opponent_color))

    {
      "Victory! 🎉",
      "You prevailed against #{opponent_display}."
    }
  end

  defp loser_overlay_copy(:completed, winner_player, winner_color) do
    winner_display = capitalize_phrase(overlay_player_display(winner_player, winner_color))

    {
      "Checkmated",
      "#{winner_display} wins this game."
    }
  end

  defp loser_overlay_copy(:resigned, winner_player, winner_color) do
    winner_display = capitalize_phrase(overlay_player_display(winner_player, winner_color))

    {
      "Defeat by resignation",
      "#{winner_display} claims the match after your resignation."
    }
  end

  defp loser_overlay_copy(_status, winner_player, winner_color) do
    winner_display = capitalize_phrase(overlay_player_display(winner_player, winner_color))

    {
      "Defeat",
      "#{winner_display} wins the game."
    }
  end

  defp overlay_class(:defeat), do: "endgame-overlay--defeat"
  defp overlay_class(_), do: "endgame-overlay--celebration"

  # Particle generation moved to LiveChessWeb.EndgameParticles

  defp overlay_player_display(player, color) do
    cond do
      player && Map.get(player, :robot?) ->
        Map.get(player, :name, "Robot")

      player && valid_player_name?(Map.get(player, :name)) ->
        Map.get(player, :name)

      true ->
        color_label(color)
    end
  end

  defp valid_player_name?(name) when is_binary(name), do: String.trim(name) != ""
  defp valid_player_name?(_), do: false

  defp capitalize_phrase(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> ""
      trimmed -> String.capitalize(trimmed)
    end
  end

  defp capitalize_phrase(_value), do: ""

  defp status_line(%{status: :waiting}), do: "Waiting for an opponent..."

  defp status_line(%{status: :active, in_check: color}) when color in [:white, :black] do
    "Check! #{human_turn(color)} king is in check"
  end

  defp status_line(%{status: status}) when status in [:active, :playing], do: "Game in progress"
  defp status_line(%{status: :completed, winner: :white}), do: "Checkmate! White wins 🎉"
  defp status_line(%{status: :completed, winner: :black}), do: "Checkmate! Black wins 🎉"

  defp status_line(%{status: :resigned, last_move: %{action: :resigned, color: color}}) do
    "#{color_label(color)} surrendered. #{opponent_label(color)} wins."
  end

  defp status_line(%{status: :resigned, winner: winner}) when winner in [:white, :black] do
    "Game ended by resignation. #{color_label(winner)} claims the win."
  end

  defp status_line(%{status: status}) do
    "Game finished (#{format_status(status)})"
  end

  defp format_status(status) when is_atom(status) do
    status
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_status(status), do: to_string(status)

  defp status_classes(%{status: :waiting}), do: "text-slate-600 dark:text-slate-300"

  defp status_classes(%{status: :active, in_check: color}) when color in [:white, :black],
    do: "text-amber-600 dark:text-amber-300 font-medium"

  defp status_classes(%{status: status}) when status in [:active, :playing],
    do: "text-slate-600 dark:text-slate-300"

  defp status_classes(%{status: :completed, winner: :white}),
    do: "text-emerald-700 dark:text-emerald-300 font-semibold"

  defp status_classes(%{status: :completed, winner: :black}),
    do: "text-emerald-700 dark:text-emerald-300 font-semibold"

  defp status_classes(%{status: :resigned}),
    do: "text-rose-600 dark:text-rose-300 font-semibold"

  defp status_classes(_), do: "text-slate-700 dark:text-slate-200"

  defp viewer_count_number(%{spectator_count: count}, _role) when is_integer(count),
    do: max(count, 0)

  defp viewer_count_number(_, _), do: 0

  defp viewer_count_label(game, role) do
    case viewer_count_number(game, role) do
      0 -> "No viewers"
      1 -> "1 viewer"
      count -> "#{count} viewers"
    end
  end

  defp update_spectator_count_from_presence(socket, topic) do
    presences = Presence.list(topic)

    # Count users with spectator role
    spectator_count =
      Enum.count(presences, fn
        {_id, %{metas: metas}} when is_list(metas) ->
          Enum.any?(metas, fn
            meta when is_map(meta) -> Map.get(meta, :role) == :spectator
            _ -> false
          end)

        _ ->
          false
      end)

    # Update game state with new spectator count
    # Handle case where game might be nil during initial mount
    case Map.get(socket.assigns, :game) do
      nil ->
        # Game not loaded yet, just return socket unchanged
        socket

      game when is_map(game) ->
        updated_game = Map.put(game, :spectator_count, spectator_count)
        assign(socket, :game, updated_game)
    end
  end

  defp viewer_count_badge_classes(game, role) do
    base =
      "inline-flex items-center gap-1 rounded-full border px-3 py-1 text-xs font-semibold transition"

    if viewer_count_number(game, role) > 0 do
      base <>
        " border-emerald-300 bg-emerald-50 text-emerald-700 dark:border-emerald-500/60 dark:bg-emerald-900/30 dark:text-emerald-100"
    else
      base <>
        " border-slate-200 bg-slate-100 text-slate-600 dark:border-slate-600 dark:bg-slate-800/60 dark:text-slate-300"
    end
  end

  defp human_turn(:white), do: "White"
  defp human_turn(:black), do: "Black"
  defp human_turn(_), do: "--"

  defp square_classes(role, cell, selected, last_move, available_moves, live_view?) do
    base =
      [
        "chess-square",
        if(cell.light?, do: "chess-square-light", else: "chess-square-dark"),
        if(selected == cell.id, do: "chess-square-active", else: nil),
        if(highlight_last_move?(last_move, cell.id),
          do: "chess-square-last-move",
          else: nil
        ),
        if(capture_highlight?(available_moves, cell, role),
          do: "chess-square-capture",
          else: nil
        ),
        if(live_view? and clickable?(role, cell), do: "cursor-pointer", else: "cursor-default")
      ]

    Enum.reject(base, &is_nil/1)
  end

  defp highlight_last_move?(%{from: from, to: to}, square)
       when is_binary(from) and is_binary(to) do
    square in [from, to]
  end

  defp highlight_last_move?(_last_move, _square), do: false

  defp clickable?(role, %{piece: %{color: color}}) when role == color, do: true
  defp clickable?(_role, _cell), do: false

  defp piece_svg(piece) do
    # Delegate to central pieces module so we can iterate on the art in one place.
    LiveChessWeb.Pieces.piece_svg(piece)
  end

  defp fetch_moves(socket, square) do
    case Games.available_moves(socket.assigns.room_id, socket.assigns.player_token, square) do
      {:ok, moves} -> moves
      _ -> []
    end
  end

  defp request_client_evaluation(socket, state) do
    # Only request evaluation for active/in-progress games, not finished games
    # This preserves the final evaluation when the game ends
    status = Map.get(state, :status)

    if Map.get(state, :current_fen) && !finished_status?(status) do
      Phoenix.LiveView.push_event(socket, "request_client_eval", %{
        fen: state.current_fen,
        depth: 12
      })
    else
      socket
    end
  end

  defp maybe_request_robot_move(socket, state) do
    # Check if it's the robot's turn and request a move from the client-side engine
    cond do
      # Not active game
      state.status != :active ->
        socket

      # No robot in game
      !has_robot_player?(state) ->
        socket

      # It's robot's turn - request move from client
      robot_turn?(state) ->
        Phoenix.LiveView.push_event(socket, "request_robot_move", %{
          fen: state.current_fen,
          depth: 12
        })

      # Not robot's turn
      true ->
        socket
    end
  end

  defp has_robot_player?(%{players: players}) do
    Map.get(players.white || %{}, :robot?) == true ||
      Map.get(players.black || %{}, :robot?) == true
  end

  defp has_robot_player?(_), do: false

  defp robot_turn?(%{turn: turn, players: players}) do
    player = Map.get(players, turn)
    Map.get(player || %{}, :robot?) == true
  end

  defp robot_turn?(_), do: false

  defp show_surrender_button?(_role, nil), do: false

  defp show_surrender_button?(role, %{status: :active}) when role in [:white, :black], do: true

  defp show_surrender_button?(_, _), do: false

  defp live_button_classes(cursor, length) do
    base =
      "inline-flex items-center rounded-full border border-slate-300 px-3 py-1 text-xs font-semibold text-slate-600 transition hover:bg-slate-100 focus:outline-none focus:ring-2 focus:ring-slate-400 focus:ring-offset-2 dark:border-slate-600 dark:text-slate-200 dark:hover:bg-slate-800 dark:focus:ring-slate-500"

    if viewing_live?(cursor, length) do
      base <> " opacity-50 cursor-not-allowed hover:bg-transparent dark:hover:bg-transparent"
    else
      base
    end
  end

  defp history_prev_disabled?(_cursor, length) when length <= 0, do: true
  defp history_prev_disabled?(cursor, _length) when is_integer(cursor) and cursor <= 0, do: true
  defp history_prev_disabled?(_cursor, _length), do: false

  defp history_next_disabled?(_cursor, length) when length <= 0, do: true

  defp history_next_disabled?(cursor, length) when is_integer(cursor) and cursor >= length,
    do: true

  defp history_next_disabled?(_cursor, _length), do: false

  attr :event, :string, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false

  defp history_nav_button(assigns) do
    classes =
      "inline-flex h-8 w-8 items-center justify-center rounded-md border border-slate-300 text-sm font-semibold text-slate-600 transition hover:bg-slate-100 focus:outline-none focus:ring-2 focus:ring-slate-400 focus:ring-offset-2 dark:border-slate-600 dark:text-slate-200 dark:hover:bg-slate-800 dark:focus:ring-slate-500"

    assigns =
      assign(
        assigns,
        :classes,
        if(assigns.disabled,
          do:
            classes <>
              " opacity-50 cursor-not-allowed hover:bg-transparent dark:hover:bg-transparent",
          else: classes
        )
      )

    ~H"""
    <button
      type="button"
      phx-click={@event}
      class={@classes}
      disabled={@disabled}
    >
      {@label}
    </button>
    """
  end

  defp show_move_dot?(available_moves, %{id: id, piece: nil}, _role) do
    available_moves && MapSet.member?(available_moves, id)
  end

  defp show_move_dot?(_available_moves, _cell, _role), do: false

  defp capture_highlight?(available_moves, %{id: id, piece: %{color: piece_color}}, role) do
    available_moves && MapSet.member?(available_moves, id) && piece_color != role
  end

  defp capture_highlight?(_available_moves, _cell, _role), do: false

  attr :game, :map, default: nil
  attr :player_token, :string, default: nil

  defp turn_indicator(assigns) do
    assigns =
      assigns
      |> assign(:indicator, turn_indicator_data(assigns.game, assigns.player_token))

    ~H"""
    <div class={"inline-flex w-fit items-center gap-2 rounded-full px-3 py-1 text-sm font-semibold transition " <> @indicator.class}>
      <span class={"h-2.5 w-2.5 rounded-full " <> @indicator.dot_class}></span>
      <span>{@indicator.label}</span>
      <%= if @indicator.sublabel do %>
        <span class="text-xs font-medium text-slate-600 dark:text-slate-300">
          {@indicator.sublabel}
        </span>
      <% end %>
    </div>
    """
  end

  attr :game, :map, default: nil
  attr :color, :atom, required: true
  attr :token, :string, default: nil

  defp player_line(assigns) do
    assigns =
      assigns
      |> assign(:slot, seat_details(assigns.game, assigns.color, assigns.token))

    ~H"""
    <div class={"rounded-lg px-4 py-3 transition-colors " <> @slot.container_class}>
      <div class="flex items-start justify-between gap-4">
        <div class="flex items-start gap-3">
          <span class={"mt-1 h-2.5 w-2.5 rounded-full " <> @slot.dot_class}></span>
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
              {@slot.role_label}
            </p>
            <p class="text-sm font-semibold text-slate-900 dark:text-slate-100">{@slot.title}</p>
            <p class="text-xs text-slate-500 dark:text-slate-400">{@slot.description}</p>
          </div>
        </div>
        <span class={"inline-flex items-center rounded-full px-2 py-1 text-xs font-medium whitespace-nowrap " <> @slot.badge_class}>
          {@slot.badge_text}
        </span>
      </div>
    </div>
    """
  end

  defp seat_details(nil, color, _token) do
    %{
      role_label: color_label(color),
      title: "Loading...",
      description: "Checking seat status...",
      container_class:
        "border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800/60",
      dot_class: "bg-slate-300",
      badge_text: "Loading",
      badge_class: "bg-slate-100 text-slate-600 dark:bg-slate-700 dark:text-slate-300"
    }
  end

  defp seat_details(game, color, token) do
    active_turn? = Map.get(game, :turn) == color

    case game.players[color] do
      nil ->
        %{
          role_label: color_label(color),
          title: "Seat available",
          description:
            if(active_turn?,
              do: "Waiting for a #{color_label(color)} player to move.",
              else: "The #{color_label(color)} seat is open for a player."
            ),
          container_class:
            if active_turn? do
              "border border-amber-200 bg-amber-50/80 dark:border-amber-500/60 dark:bg-amber-900/25"
            else
              "border border-dashed border-slate-300 bg-white dark:border-slate-600 dark:bg-slate-900/40"
            end,
          dot_class:
            if active_turn? do
              "bg-amber-400 animate-pulse"
            else
              "border border-slate-300 bg-transparent"
            end,
          badge_text: if(active_turn?, do: "Needed", else: "Open"),
          badge_class:
            if active_turn? do
              "bg-amber-100 text-amber-700 dark:bg-amber-800 dark:text-amber-100"
            else
              "bg-slate-100 text-slate-600 dark:bg-slate-700 dark:text-slate-200"
            end
        }

      %{token: ^token, connected?: connected?} ->
        base_container =
          "border border-emerald-300 bg-emerald-50 dark:border-emerald-500/60 dark:bg-emerald-900/40 shadow-sm"

        %{
          role_label: color_label(color),
          title: "You",
          description:
            if(active_turn?,
              do: "It's your turn. Move your #{color_label(color)} pieces.",
              else: "Waiting for #{opponent_label(color)} to move."
            ),
          container_class:
            if active_turn? do
              base_container <> " ring-2 ring-emerald-300/70"
            else
              base_container
            end,
          dot_class:
            if active_turn? do
              "bg-emerald-500 animate-pulse"
            else
              "bg-emerald-500"
            end,
          badge_text:
            cond do
              active_turn? -> "Your move"
              connected? -> "Waiting"
              true -> "Reconnecting"
            end,
          badge_class:
            cond do
              active_turn? ->
                "bg-emerald-100 text-emerald-700 dark:bg-emerald-800 dark:text-emerald-100"

              connected? ->
                "bg-slate-100 text-slate-600 dark:bg-slate-700 dark:text-slate-200"

              true ->
                "bg-amber-100 text-amber-700 dark:bg-amber-800 dark:text-amber-100"
            end
        }

      %{robot?: true} = player ->
        base_container =
          "border border-indigo-200 bg-indigo-50 dark:border-indigo-500/50 dark:bg-indigo-900/30 shadow-sm"

        name = Map.get(player, :name, "Robot opponent")

        %{
          role_label: color_label(color),
          title: name,
          description:
            if(active_turn?,
              do: "The robot is thinking through the next move.",
              else: "Waiting for you to move."
            ),
          container_class:
            if active_turn? do
              base_container <> " ring-2 ring-indigo-300/70"
            else
              base_container
            end,
          dot_class:
            if active_turn? do
              "bg-indigo-400 animate-pulse"
            else
              "bg-indigo-400"
            end,
          badge_text: "Robot",
          badge_class: "bg-indigo-100 text-indigo-700 dark:bg-indigo-800 dark:text-indigo-100"
        }

      %{connected?: true} ->
        base_container =
          "border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800/60"

        %{
          role_label: color_label(color),
          title: "Opponent ready",
          description:
            if active_turn? do
              "The #{color_label(color)} player is thinking."
            else
              "#{color_label(color)} will move after you."
            end,
          container_class:
            if active_turn? do
              base_container <> " ring-2 ring-sky-300/60"
            else
              base_container
            end,
          dot_class:
            if active_turn? do
              "bg-sky-400 animate-pulse"
            else
              "bg-emerald-400"
            end,
          badge_text: if(active_turn?, do: "Their move", else: "Online"),
          badge_class:
            if active_turn? do
              "bg-sky-100 text-sky-700 dark:bg-sky-800 dark:text-sky-100"
            else
              "bg-emerald-100 text-emerald-700 dark:bg-emerald-800 dark:text-emerald-100"
            end
        }

      %{connected?: false} ->
        %{
          role_label: color_label(color),
          title: "Opponent disconnected",
          description:
            if active_turn? do
              "Waiting for #{color_label(color)} to reconnect and move."
            else
              "They will rejoin automatically when back online."
            end,
          container_class:
            "border border-amber-200 bg-amber-50/80 dark:border-amber-500/50 dark:bg-amber-900/30",
          dot_class:
            if active_turn? do
              "bg-amber-400 animate-pulse"
            else
              "bg-amber-400"
            end,
          badge_text: if(active_turn?, do: "Paused", else: "Offline"),
          badge_class: "bg-amber-100 text-amber-700 dark:bg-amber-800 dark:text-amber-100"
        }
    end
  end

  defp maybe_play_move_sound(socket, nil, _new_state), do: socket

  defp maybe_play_move_sound(socket, previous_state, new_state) do
    previous_last = previous_state && Map.get(previous_state, :last_move)
    new_last = Map.get(new_state, :last_move)
    player_color = color_for_token(new_state, socket.assigns.player_token)

    cond do
      new_last == nil ->
        socket

      previous_last == new_last ->
        socket

      player_color == new_last.color ->
        socket

      true ->
        socket
        |> push_event("play-move-sound", %{})
        |> push_event("vibrate-opponent-move", %{})
    end
  end

  defp maybe_play_join_sound(socket, nil, _new_state), do: socket

  defp maybe_play_join_sound(socket, previous_state, new_state) do
    joined_color =
      [:white, :black]
      |> Enum.find(fn color ->
        player_presence(previous_state, color) == nil and
          player_presence(new_state, color) != nil
      end)

    if joined_color do
      socket
      |> push_event("play-join-sound", %{color: color_label(joined_color)})
      |> push_event("vibrate-join", %{})
    else
      socket
    end
  end

  defp player_presence(nil, _color), do: nil

  defp player_presence(%{players: players}, color) do
    Map.get(players, color)
  end

  defp player_presence(_other, _color), do: nil

  defp game_pending?(%{status: status}), do: not finished_status?(status)

  defp game_pending?(_), do: false

  defp finished_status?(status) when is_atom(status), do: status in @finished_statuses
  defp finished_status?(_), do: false

  defp infer_role_from_state(%{players: players}, token) when is_binary(token) do
    cond do
      match?(%{token: ^token}, players.white) -> :white
      match?(%{token: ^token}, players.black) -> :black
      true -> nil
    end
  end

  defp infer_role_from_state(_state, _token), do: nil

  defp color_for_token(state, token), do: infer_role_from_state(state, token)

  defp color_label(color) do
    color
    |> Atom.to_string()
    |> String.capitalize()
  end

  defp opponent_label(:white), do: color_label(:black)
  defp opponent_label(:black), do: color_label(:white)

  defp opposite_color(:white), do: :black
  defp opposite_color(:black), do: :white

  defp turn_indicator_data(nil, _player_token) do
    %{
      class: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-200",
      dot_class: "bg-slate-400",
      label: "Loading game",
      sublabel: nil
    }
  end

  defp turn_indicator_data(game, player_token) do
    players = Map.get(game, :players, %{})
    active_color = Map.get(game, :turn) || :white
    active_label = color_label(active_color)
    active_player = Map.get(players, active_color)
    viewer_color = color_for_token(game, player_token)
    spectator? = viewer_color not in [:white, :black]
    robot_active? = active_player && Map.get(active_player, :robot?)
    status = Map.get(game, :status)
    winner = Map.get(game, :winner)

    robot_color =
      [:white, :black]
      |> Enum.find(fn color ->
        player = Map.get(players, color)
        player && Map.get(player, :robot?)
      end)

    finished_indicator =
      cond do
        status == :completed and viewer_color in [:white, :black] and winner == viewer_color ->
          opponent_color = opposite_color(viewer_color)
          opponent = Map.get(players, opponent_color)
          opponent_display = overlay_player_display(opponent, opponent_color)
          is_robot_opponent = opponent && Map.get(opponent, :robot?) == true

          sublabel =
            if is_robot_opponent do
              "You defeated #{opponent_display}."
            else
              "#{color_label(viewer_color)} checkmated #{opponent_display}."
            end

          %{
            class:
              "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/60 dark:text-emerald-100 ring-1 ring-inset ring-emerald-300/70",
            dot_class: "bg-emerald-400",
            label: "You won",
            sublabel: sublabel
          }

        status == :completed and viewer_color in [:white, :black] and winner in [:white, :black] ->
          winner_player = Map.get(players, winner)
          winner_display = overlay_player_display(winner_player, winner)
          robot_win? = winner_player && Map.get(winner_player, :robot?) == true

          sublabel =
            if robot_win? do
              "#{winner_display} delivered checkmate."
            else
              "#{winner_display} wins the game."
            end

          %{
            class:
              "bg-rose-100 text-rose-600 dark:bg-rose-900/60 dark:text-rose-200 ring-1 ring-inset ring-rose-300/60",
            dot_class: "bg-rose-400",
            label: if(robot_win?, do: "Robot won", else: "Game over"),
            sublabel: sublabel
          }

        status == :completed and robot_color ->
          outcome_label =
            cond do
              winner == robot_color -> "Robot won"
              winner in [:white, :black] -> "Robot lost"
              true -> "Game over"
            end

          sublabel =
            cond do
              winner == robot_color -> "#{color_label(robot_color)} delivers mate."
              winner in [:white, :black] -> "#{color_label(winner)} wins the game."
              true -> "The game has concluded."
            end

          %{
            class: "bg-indigo-100 text-indigo-700 dark:bg-indigo-900/60 dark:text-indigo-100",
            dot_class: "bg-indigo-400",
            label: outcome_label,
            sublabel: sublabel
          }

        status == :completed ->
          %{
            class: "bg-slate-100 text-slate-700 dark:bg-slate-800/80 dark:text-slate-100",
            dot_class: "bg-slate-400",
            label:
              if(winner in [:white, :black], do: "#{color_label(winner)} wins", else: "Game over"),
            sublabel: "Match finished"
          }

        true ->
          nil
      end

    if finished_indicator do
      finished_indicator
    else
      cond do
        active_player && not spectator? && player_token && active_player.token == player_token ->
          %{
            class:
              "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/60 dark:text-emerald-100 ring-1 ring-inset ring-emerald-300/70",
            dot_class: "bg-emerald-500 animate-pulse",
            label: "Your move",
            sublabel: "#{active_label} pieces"
          }

        robot_active? && not spectator? ->
          %{
            class: "bg-indigo-100 text-indigo-700 dark:bg-indigo-900/60 dark:text-indigo-100",
            dot_class: "bg-indigo-400 animate-pulse",
            label: "Robot thinking",
            sublabel: "#{active_label} pieces"
          }

        robot_active? && spectator? ->
          %{
            class: "bg-indigo-100/70 text-indigo-700 dark:bg-indigo-900/50 dark:text-indigo-100",
            dot_class: "bg-indigo-400 animate-pulse",
            label: "Robot to move",
            sublabel: "Spectating · #{opponent_label(active_color)} waits"
          }

        spectator? && active_player && active_player.connected? ->
          %{
            class: "bg-slate-100 text-slate-700 dark:bg-slate-800/80 dark:text-slate-100",
            dot_class: "bg-sky-400 animate-pulse",
            label: "#{active_label} to move",
            sublabel: "Spectating · #{opponent_label(active_color)} waits"
          }

        spectator? && active_player ->
          %{
            class: "bg-amber-100 text-amber-700 dark:bg-amber-900/50 dark:text-amber-100",
            dot_class: "bg-amber-400 animate-pulse",
            label: "#{active_label} to move",
            sublabel: "Spectating · #{opponent_label(active_color)} reconnecting"
          }

        active_player && active_player.connected? ->
          %{
            class: "bg-slate-100 text-slate-700 dark:bg-slate-800/80 dark:text-slate-100",
            dot_class: "bg-sky-400 animate-pulse",
            label: "#{active_label} to move",
            sublabel: "Opponent is thinking"
          }

        active_player ->
          %{
            class: "bg-amber-100 text-amber-700 dark:bg-amber-900/50 dark:text-amber-100",
            dot_class: "bg-amber-400 animate-pulse",
            label: "#{active_label} to move",
            sublabel: "Opponent reconnecting"
          }

        spectator? ->
          %{
            class: "bg-slate-100 text-slate-700 dark:bg-slate-800/60 dark:text-slate-100",
            dot_class: "bg-slate-400",
            label: "Spectating",
            sublabel: "Waiting for players to join"
          }

        true ->
          %{
            class: "bg-amber-100 text-amber-700 dark:bg-amber-900/50 dark:text-amber-100",
            dot_class: "bg-amber-400 animate-pulse",
            label: "#{active_label} to move",
            sublabel: "Seat still open"
          }
      end
    end
  end
end
