defmodule LiveChessWeb.GameLive do
  use LiveChessWeb, :live_view

  alias LiveChess.Games

  @impl true
  def mount(%{"room_id" => room_id}, _session, socket) do
    if connected?(socket), do: Games.subscribe(room_id)

    socket =
      socket
      |> assign(:room_id, room_id)
      |> assign(:selected_square, nil)
      |> assign(:available_moves, MapSet.new())
      |> assign(:error_message, nil)
      |> assign(:role, :spectator)
      |> assign(:game, nil)
      |> assign(:share_url, nil)
      |> assign(:player_token, socket.assigns.player_token)

    case Games.connect(room_id, socket.assigns.player_token) do
      {:ok, %{role: role, state: state}} ->
        socket =
          socket
          |> assign(:role, role)
          |> assign(:game, state)
          |> assign(:share_url, build_share_url(room_id))

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

      true ->
        attempt_move(socket, socket.assigns.selected_square, square)
    end
  end

  @impl true
  def handle_info({:game_state, state}, socket) do
    socket =
      socket
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl px-4 py-8">
      <div class="flex flex-col gap-6 lg:flex-row">
        <div class="flex-1">
          <%= if @game do %>
            <div class="rounded-lg border border-slate-200 bg-slate-50 p-4 shadow-sm">
              <div class="flex items-center justify-between">
                <h2 class="text-lg font-semibold text-slate-800">Room {@room_id}</h2>
                <div class="text-sm text-slate-600">Turn: {human_turn(@game.turn)}</div>
              </div>
              <div class={"mt-2 text-sm " <> status_classes(@game)}>{status_line(@game)}</div>

              <div class="mt-4 grid grid-cols-8 gap-1">
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
                      <span class="text-3xl font-semibold">{piece_symbol(cell.piece)}</span>
                      <%= if show_move_dot?(@available_moves, cell, @role) do %>
                        <span class="pointer-events-none absolute inset-0 flex items-center justify-center">
                          <span class="h-3 w-3 rounded-full bg-emerald-600/60"></span>
                        </span>
                      <% end %>
                      <span class="sr-only">{cell.id}</span>
                    </button>
                  <% end %>
                <% end %>
              </div>
            </div>
          <% else %>
            <div class="rounded-md border border-amber-300 bg-amber-50 p-4 text-amber-900">
              Preparing game state...
            </div>
          <% end %>
        </div>

        <div class="w-full max-w-sm space-y-4">
          <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
            <h3 class="text-lg font-semibold text-slate-800">Share</h3>
            <p class="mt-1 text-sm text-slate-600">Send this link to a friend so they can join.</p>
            <div class="mt-3">
              <input
                type="text"
                readonly
                value={@share_url}
                class="w-full rounded-md border border-slate-300 bg-slate-100 px-3 py-2 text-sm text-slate-700"
              />
              <p class="mt-2 text-sm text-slate-500">
                Room code: <span class="font-mono uppercase">{@room_id}</span>
              </p>
            </div>
          </div>

          <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
            <h3 class="text-lg font-semibold text-slate-800">Players</h3>
            <div class="mt-3 space-y-2 text-sm text-slate-700">
              <.player_line game={@game} color={:white} token={@player_token} />
              <.player_line game={@game} color={:black} token={@player_token} />
            </div>

            <%= if joinable?(@role, @game) do %>
              <button
                type="button"
                phx-click="claim-seat"
                class="mt-4 w-full rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-500 focus:outline-none focus:ring-2 focus:ring-emerald-400 focus:ring-offset-2"
              >
                Join the game
              </button>
            <% end %>
          </div>

          <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
            <h3 class="text-lg font-semibold text-slate-800">Moves</h3>
            <div class="mt-2 max-h-80 space-y-1 overflow-y-auto text-sm text-slate-700">
              <%= if @game && @game.history != [] do %>
                <%= for {move, index} <- Enum.with_index(@game.history, 1) do %>
                  <div>
                    <span class="font-semibold">{index}.</span>
                    <span class="ml-2 font-mono">{move}</span>
                  </div>
                <% end %>
              <% else %>
                <p class="text-slate-500">No moves yet.</p>
              <% end %>
            </div>
          </div>

          <%= if @error_message do %>
            <div class="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-700">
              {@error_message}
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp status_line(%{status: :waiting}), do: "Waiting for an opponent..."
  defp status_line(%{status: status}) when status in [:active, :playing], do: "Game in progress"
  defp status_line(%{status: :completed, winner: :white}), do: "Checkmate! White wins 🎉"
  defp status_line(%{status: :completed, winner: :black}), do: "Checkmate! Black wins 🎉"

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

  defp status_classes(%{status: :waiting}), do: "text-slate-600"
  defp status_classes(%{status: status}) when status in [:active, :playing], do: "text-slate-600"
  defp status_classes(%{status: :completed, winner: :white}), do: "text-emerald-700 font-semibold"
  defp status_classes(%{status: :completed, winner: :black}), do: "text-emerald-700 font-semibold"
  defp status_classes(_), do: "text-slate-700"

  defp joinable?(role, game) do
    (role not in [:white, :black] and game) &&
      Enum.any?([:white, :black], &(game.players[&1] == nil))
  end

  defp human_turn(:white), do: "White"
  defp human_turn(:black), do: "Black"
  defp human_turn(_), do: "--"

  defp square_classes(role, cell, selected, last_move, available_moves) do
    base =
      [
        "relative aspect-square w-full rounded-sm border text-center transition",
        if(cell.light?, do: "bg-emerald-50", else: "bg-emerald-100"),
        if(selected == cell.id, do: "ring-2 ring-emerald-500", else: nil),
        if(last_move && cell.id in [last_move.from, last_move.to],
          do: "border-emerald-400",
          else: "border-transparent"
        ),
        if(capture_highlight?(available_moves, cell, role),
          do: "ring-2 ring-emerald-400",
          else: nil
        ),
        if(clickable?(role, cell), do: "hover:brightness-95", else: "cursor-default")
      ]

    Enum.reject(base, &is_nil/1)
  end

  defp clickable?(role, %{piece: %{color: color}}) when role == color, do: true
  defp clickable?(_role, _cell), do: false

  defp piece_symbol(nil), do: ""

  # Unicode chess symbols
  defp piece_symbol(%{color: :white, type: "k"}), do: "♔"
  defp piece_symbol(%{color: :white, type: "q"}), do: "♕"
  defp piece_symbol(%{color: :white, type: "r"}), do: "♖"
  defp piece_symbol(%{color: :white, type: "b"}), do: "♗"
  defp piece_symbol(%{color: :white, type: "n"}), do: "♘"
  defp piece_symbol(%{color: :white, type: "p"}), do: "♙"
  defp piece_symbol(%{color: :black, type: "k"}), do: "♚"
  defp piece_symbol(%{color: :black, type: "q"}), do: "♛"
  defp piece_symbol(%{color: :black, type: "r"}), do: "♜"
  defp piece_symbol(%{color: :black, type: "b"}), do: "♝"
  defp piece_symbol(%{color: :black, type: "n"}), do: "♞"
  defp piece_symbol(%{color: :black, type: "p"}), do: "♟"
  defp piece_symbol(_), do: "?"

  defp fetch_moves(socket, square) do
    case Games.available_moves(socket.assigns.room_id, socket.assigns.player_token, square) do
      {:ok, moves} -> moves
      _ -> []
    end
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
  attr :color, :atom, required: true
  attr :token, :string, required: true

  defp player_line(assigns) do
    assigns =
      assigns
      |> assign(:label, assigns.color |> Atom.to_string() |> String.capitalize())
      |> assign(:seat_status, seat_status(assigns.game, assigns.color, assigns.token))
      |> assign(:connection_state, connection_state(assigns.game, assigns.color))

    ~H"""
    <div class="flex items-center justify-between rounded-md border border-slate-200 bg-slate-50 px-3 py-2">
      <div>
        <span class="font-medium">{@label}</span>
        <span class="ml-2 text-xs uppercase tracking-wide text-slate-500">{@seat_status}</span>
      </div>
      <div class="text-xs text-slate-500">{@connection_state}</div>
    </div>
    """
  end

  defp seat_status(nil, _color, _token), do: "loading"

  defp seat_status(game, color, token) do
    case game.players[color] do
      nil -> "open seat"
      %{token: ^token} -> "you"
      %{token: _} -> "taken"
    end
  end

  defp connection_state(nil, _color), do: "--"

  defp connection_state(game, color) do
    case game.players[color] do
      nil -> "open"
      %{connected?: true} -> "connected"
      _ -> "offline"
    end
  end
end
