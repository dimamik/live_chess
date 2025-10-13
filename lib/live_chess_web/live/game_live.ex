defmodule LiveChessWeb.GameLive do
  use LiveChessWeb, :live_view

  alias LiveChess.Games

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
      |> assign(:page_title, "LiveView Chess")

    if connected?(socket) do
      Games.subscribe(room_id)

      case Games.connect(room_id, socket.assigns.player_token) do
        {:ok, %{role: role, state: state}} ->
          socket =
            socket
            |> assign(:role, role)
            |> assign(:game, state)
            |> assign(:board_ready?, true)

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
           |> assign(:game, state)}

        _ ->
          {:ok, socket}
      end
    end
  end

  @impl true
  def handle_event("claim-seat", _params, socket) do
    case Games.join_game(socket.assigns.room_id, socket.assigns.player_token) do
      {:ok, %{role: role, state: state}} ->
        {:noreply,
         socket
         |> assign(:role, role)
         |> assign(:game, state)
         |> assign(:error_message, nil)}

      {:error, :slot_taken} ->
        {:noreply, assign(socket, :error_message, "Both seats are already taken.")}

      {:error, _} ->
        {:noreply, assign(socket, :error_message, "Unable to claim a seat right now.")}
    end
  end

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

  def handle_event("surrender", _params, socket) do
    if show_surrender_button?(socket.assigns.role, socket.assigns.game) do
      case Games.resign(socket.assigns.room_id, socket.assigns.player_token) do
        {:ok, %{state: state}} ->
          {:noreply,
           socket
           |> assign(:game, state)
           |> assign(:error_message, nil)}

        {:error, :game_not_active} ->
          {:noreply, assign(socket, :error_message, "The game is no longer active.")}

        {:error, :not_authorized} ->
          {:noreply, assign(socket, :error_message, "Only seated players can surrender.")}

        {:error, message} when is_binary(message) ->
          {:noreply, assign(socket, :error_message, message)}

        {:error, _reason} ->
          {:noreply, assign(socket, :error_message, "Unable to surrender right now.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_square", %{"square" => square}, socket) do
    cond do
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

    socket =
      socket
      |> maybe_play_join_sound(previous_game, state)
      |> maybe_play_move_sound(previous_game, state)
      |> assign(:game, state)
      |> assign(:error_message, nil)
      |> maybe_reset_selection(state)

    {:noreply, maybe_auto_join(socket, state)}
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
         |> assign(:game, state)
         |> assign(:selected_square, nil)
         |> assign(:available_moves, MapSet.new())
         |> assign(:error_message, nil)}

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

  defp oriented_board(%{board: board}, role), do: LiveChess.Games.Board.oriented(board, role)
  defp oriented_board(_nil, _role), do: []

  defp maybe_auto_join(socket, state) do
    cond do
      socket.assigns.role in [:white, :black] ->
        socket

      _seat = available_seat(state) ->
        case Games.join_game(socket.assigns.room_id, socket.assigns.player_token) do
          {:ok, %{role: role, state: new_state}} ->
            socket
            |> assign(:role, role)
            |> assign(:game, new_state)
            |> assign(:error_message, nil)

          {:error, :slot_taken} ->
            socket

          {:error, _} ->
            socket
        end

      true ->
        socket
    end
  end

  defp available_seat(%{players: players}) do
    cond do
      players.black == nil -> :black
      players.white == nil -> :white
      true -> nil
    end
  end

  defp available_seat(_), do: nil

  defp determine_initial_role(state, token, fallback) do
    infer_role_from_state(state, token) || available_seat(state) || fallback
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="game-surface" phx-hook="SoundEffects" class="mx-auto max-w-6xl px-4 py-8">
      <div class="flex flex-col gap-6 lg:flex-row">
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
                      phx-click="surrender"
                      class="inline-flex items-center gap-2 rounded-full border border-rose-300 px-3 py-1 text-sm font-medium text-rose-600 transition hover:bg-rose-50 focus:outline-none focus:ring-2 focus:ring-rose-400 focus:ring-offset-2 dark:border-rose-500/60 dark:text-rose-200 dark:hover:bg-rose-900/30 dark:focus:ring-rose-400/70"
                    >
                      Surrender
                    </button>
                  <% end %>
                </div>
                <.turn_indicator game={@game} player_token={@player_token} />
              </div>
              <div class={"mt-2 text-sm " <> status_classes(@game)}>{status_line(@game)}</div>

              <div class="chess-board-grid">
                <%= for row <- oriented_board(@game, @role) do %>
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
                          @game.last_move,
                          @available_moves
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

        <div class="w-full max-w-sm space-y-4">
          <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900">
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

          <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900">
            <h3 class="text-lg font-semibold text-slate-800 dark:text-slate-100">Players</h3>
            <div class="mt-3 space-y-2 text-sm text-slate-700 dark:text-slate-300">
              <.player_line game={@game} color={:white} token={@player_token} />
              <.player_line game={@game} color={:black} token={@player_token} />
            </div>
          </div>

          <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900">
            <h3 class="text-lg font-semibold text-slate-800 dark:text-slate-100">Advantage</h3>
            <.evaluation_panel evaluation={@game && Map.get(@game, :evaluation)} />
          </div>

          <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900">
            <h3 class="text-lg font-semibold text-slate-800 dark:text-slate-100">Moves</h3>
            <div class="mt-2 max-h-80 space-y-1 overflow-y-auto text-sm text-slate-700 dark:text-slate-300">
              <%= if @game && @game.history != [] do %>
                <%= for {move, index} <- Enum.with_index(@game.history, 1) do %>
                  <div>
                    <span class="font-semibold">{index}.</span>
                    <span class="ml-2 font-mono">{move}</span>
                  </div>
                <% end %>
              <% else %>
                <p class="text-slate-500 dark:text-slate-400">No moves yet.</p>
              <% end %>
            </div>
          </div>

          <%= if @error_message do %>
            <div class="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-700 dark:border-red-500/60 dark:bg-red-900/40 dark:text-red-200">
              {@error_message}
            </div>
          <% end %>
        </div>
      </div>
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
    </div>
    """
  end

  attr :evaluation, :any, default: nil

  def evaluation_panel(%{evaluation: nil} = assigns) do
    ~H"""
    <div class="mt-2 flex h-20 items-center justify-center">
      <div class="h-3/5 w-full max-w-xs animate-pulse rounded-full bg-slate-200 dark:bg-slate-700" />
    </div>
    """
  end

  def evaluation_panel(assigns) do
    white_pct = assigns.evaluation.white_percentage
    black_pct = max(0.0, 100.0 - white_pct)

    assigns =
      assigns
      |> assign(:white_pct, white_pct)
      |> assign(:white_pct_display, format_percentage(white_pct))
      |> assign(:black_pct_display, format_percentage(black_pct))

    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
        <span class="text-left text-slate-700 dark:text-slate-200">White {@white_pct_display}%</span>
        <span class={"text-sm font-semibold " <> score_text_class(@evaluation)}>
          {@evaluation.display_score}
        </span>
        <span class="text-right text-slate-700 dark:text-slate-200">Black {@black_pct_display}%</span>
      </div>
      <div class="relative h-4 w-full overflow-hidden rounded-full border border-slate-300 bg-slate-900 shadow-inner dark:border-slate-600 dark:bg-slate-800">
        <div
          class="absolute inset-y-0 left-0 bg-emerald-400 transition-all duration-500 ease-in-out dark:bg-emerald-500/80"
          style={"width: #{@white_pct}%"}
        />
      </div>
      <p class="text-center text-xs text-slate-600 dark:text-slate-400">
        {evaluation_caption(@evaluation)}
      </p>
    </div>
    """
  end

  defp evaluation_caption(%{advantage: :white, display_score: score}),
    do: "White is better (#{score})"

  defp evaluation_caption(%{advantage: :black, display_score: score}),
    do: "Black is better (#{score})"

  defp evaluation_caption(%{display_score: score}), do: "Even position (#{score})"

  defp format_percentage(value) when is_number(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary([{:decimals, 1}])
  end

  defp format_percentage(_), do: "0.0"

  defp score_text_class(%{advantage: :white}), do: "text-emerald-500"
  defp score_text_class(%{advantage: :black}), do: "text-slate-500 dark:text-slate-300"
  defp score_text_class(_), do: "text-slate-500 dark:text-slate-300"

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

  defp human_turn(:white), do: "White"
  defp human_turn(:black), do: "Black"
  defp human_turn(_), do: "--"

  defp square_classes(role, cell, selected, last_move, available_moves) do
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
        if(clickable?(role, cell), do: "cursor-pointer", else: "cursor-default")
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

  defp piece_svg(nil), do: nil

  defp piece_svg(%{color: color, type: type}) do
    assigns = %{color: color, shape: piece_shape(type)}

    ~H"""
    <svg viewBox="0 0 64 64" class={"piece-svg piece-#{@color}"} role="img" aria-hidden="true">
      {@shape}
    </svg>
    """
  end

  defp piece_shape("p") do
    assigns = %{}

    ~H"""
    <circle class="piece-detail" cx="32" cy="20" r="6" />
    <path class="piece-body" d="M24 48h16l3-12c0-6.5-5-12-11-12s-11 5.5-11 12z" />
    <rect class="piece-base" x="20" y="48" width="24" height="8" rx="2" />
    """
  end

  defp piece_shape("r") do
    assigns = %{}

    ~H"""
    <path class="piece-detail" d="M20 20h6v-6h6v6h4v-6h6v6h6v8H20z" />
    <path class="piece-body" d="M18 28h28v24h6v10H12V52h6z" />
    <rect class="piece-base" x="16" y="50" width="32" height="6" rx="2" />
    """
  end

  defp piece_shape("n") do
    assigns = %{}

    ~H"""
    <path
      class="piece-body"
      d="M20 52V36l12-14-8-4 14-8 10 10-4 6 6 8v18h-8l-6 8H20z"
    />
    <circle class="piece-dot" cx="40" cy="20" r="2.4" />
    <path class="piece-line" d="M26 40c6 2 10 8 10 16" />
    <rect class="piece-base" x="18" y="50" width="28" height="6" rx="2" />
    """
  end

  defp piece_shape("b") do
    assigns = %{}

    ~H"""
    <path
      class="piece-body"
      d="M32 12c-8 0-14 6.6-14 15 0 5.4 2.4 9.9 6.6 13.2L20 48v8h24v-8l-4.6-7.8C43.5 37 46 32.6 46 27c0-8.4-6-15-14-15z"
    />
    <path class="piece-line" d="M24 30l16-12" />
    <circle class="piece-detail" cx="32" cy="18" r="3" />
    <rect class="piece-base" x="18" y="50" width="28" height="6" rx="2" />
    """
  end

  defp piece_shape("q") do
    assigns = %{}

    ~H"""
    <circle class="piece-detail" cx="18" cy="20" r="3" />
    <circle class="piece-detail" cx="32" cy="14" r="4" />
    <circle class="piece-detail" cx="46" cy="20" r="3" />
    <path class="piece-body" d="M18 24h28l6 10-8 10 4 6v8H16v-8l4-6-8-10z" />
    <rect class="piece-base" x="16" y="50" width="32" height="6" rx="2" />
    """
  end

  defp piece_shape("k") do
    assigns = %{}

    ~H"""
    <path class="piece-detail" d="M30 8h4v6h6v4h-6v6h-4v-6h-6v-4h6z" />
    <path class="piece-body" d="M22 28h20l6 8-8 10 4 6v8H20v-8l4-6-8-10z" />
    <rect class="piece-base" x="18" y="50" width="28" height="6" rx="2" />
    """
  end

  defp piece_shape(_type) do
    assigns = %{}

    ~H"""
    <rect class="piece-body" x="24" y="20" width="16" height="24" rx="4" />
    <rect class="piece-base" x="18" y="50" width="28" height="6" rx="2" />
    """
  end

  defp fetch_moves(socket, square) do
    case Games.available_moves(socket.assigns.room_id, socket.assigns.player_token, square) do
      {:ok, moves} -> moves
      _ -> []
    end
  end

  defp show_surrender_button?(_role, nil), do: false

  defp show_surrender_button?(role, %{status: :active}) when role in [:white, :black], do: true

  defp show_surrender_button?(_, _), do: false

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
      new_last == nil -> socket
      previous_last == new_last -> socket
      player_color == new_last.color -> socket
      true -> push_event(socket, "play-move-sound", %{})
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
      push_event(socket, "play-join-sound", %{color: color_label(joined_color)})
    else
      socket
    end
  end

  defp player_presence(nil, _color), do: nil

  defp player_presence(%{players: players}, color) do
    Map.get(players, color)
  end

  defp player_presence(_other, _color), do: nil

  defp game_pending?(%{status: status}) do
    finished_statuses = [
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

    status not in finished_statuses
  end

  defp game_pending?(_), do: false

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

    cond do
      active_player && not spectator? && player_token && active_player.token == player_token ->
        %{
          class:
            "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/60 dark:text-emerald-100 ring-1 ring-inset ring-emerald-300/70",
          dot_class: "bg-emerald-500 animate-pulse",
          label: "Your move",
          sublabel: "#{active_label} pieces"
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
