defmodule LiveChessWeb.LobbyLive do
  use LiveChessWeb, :live_view

  alias LiveChess.Games

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Live Chess Lobby")
     |> assign(:room_code, "")
     |> assign(:error, nil)
     |> assign(:creating?, false)
     |> assign(:creating_robot?, false)
     |> assign(:joining?, false)}
  end

  @impl true
  def handle_event("create_room", _params, socket) do
    socket =
      socket |> assign(:creating?, true) |> assign(:creating_robot?, false) |> assign(:error, nil)

    case Games.create_game(socket.assigns.player_token) do
      {:ok, room_id} ->
        {:noreply, push_navigate(socket, to: ~p"/game/#{room_id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:creating?, false)
         |> assign(:error, format_create_error(reason))}
    end
  end

  def handle_event("create_robot_game", _params, socket) do
    socket =
      socket
      |> assign(:creating?, false)
      |> assign(:creating_robot?, true)
      |> assign(:error, nil)

    case Games.create_robot_game(socket.assigns.player_token) do
      {:ok, room_id} ->
        {:noreply, push_navigate(socket, to: ~p"/game/#{room_id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:creating_robot?, false)
         |> assign(:error, format_robot_error(reason))}

      _other ->
        {:noreply,
         socket
         |> assign(:creating_robot?, false)
         |> assign(:error, format_robot_error(:unknown))}
    end
  end

  def handle_event("update_room", %{"room_code" => room_code}, socket) do
    {:noreply, assign(socket, :room_code, normalize_room(room_code))}
  end

  def handle_event("join_game", _params, socket) do
    room_id = socket.assigns.room_code

    if room_id == "" do
      {:noreply, assign(socket, :error, "Enter a room code to join.")}
    else
      socket = assign(socket, joining?: true, error: nil)

      case Games.join_game(room_id, socket.assigns.player_token) do
        {:ok, %{role: role}} when role in [:white, :black] ->
          {:noreply, push_navigate(socket, to: ~p"/game/#{room_id}")}

        {:error, :slot_taken} ->
          {:noreply,
           socket
           |> assign(:joining?, false)
           |> assign(:error, "Both seats are already taken.")}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:joining?, false)
           |> assign(:error, "Unable to join that room. Check the code and try again.")}

        _ ->
          {:noreply,
           socket
           |> assign(:joining?, false)
           |> assign(:error, "Unable to join that room right now.")}
      end
    end
  end

  defp normalize_room(room_code) do
    room_code
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp format_create_error(:slot_taken), do: "This room already has a host. Try joining instead."
  defp format_create_error(_), do: "We couldn't create a room. Please try again."

  defp format_robot_error(:slot_taken),
    do: "All seats are already taken. Try creating a new game."

  defp format_robot_error(:robot_already_present), do: "This room already has a robot opponent."
  defp format_robot_error(_), do: "We couldn't start a robot game. Please try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl px-6 py-12">
      <h1 class="text-3xl font-semibold text-slate-900 dark:text-slate-100">Live Chess</h1>
      <p class="mt-2 text-slate-600 dark:text-slate-300">
        Create a room to play or join one with a room code.
      </p>

      <div class="mt-8 space-y-6">
        <div class="grid gap-3 sm:grid-cols-2">
          <button
            type="button"
            phx-click="create_room"
            phx-disable-with="Creating..."
            class="rounded-md bg-emerald-600 px-4 py-3 text-lg font-medium text-white hover:bg-emerald-500 focus:outline-none focus:ring-2 focus:ring-emerald-400 focus:ring-offset-2 disabled:opacity-60 dark:focus:ring-offset-slate-900"
            disabled={@creating_robot?}
          >
            <%= if @creating? do %>
              Creating room...
            <% else %>
              Create Room
            <% end %>
          </button>

          <button
            type="button"
            phx-click="create_robot_game"
            phx-disable-with="Starting..."
            class="rounded-md bg-slate-900 px-4 py-3 text-lg font-medium text-white hover:bg-slate-700 focus:outline-none focus:ring-2 focus:ring-slate-500 focus:ring-offset-2 disabled:opacity-60 dark:bg-slate-200 dark:text-slate-900 dark:hover:bg-slate-100 dark:focus:ring-slate-200 dark:focus:ring-offset-slate-900"
            disabled={@creating?}
          >
            <%= if @creating_robot? do %>
              Starting robot match...
            <% else %>
              Play vs Robot
            <% end %>
          </button>
        </div>

        <div class="rounded-lg border border-slate-200 bg-white p-6 shadow-sm dark:border-slate-700 dark:bg-slate-900">
          <h2 class="text-xl font-semibold text-slate-800 dark:text-slate-100">Join a Room</h2>
          <form phx-submit="join_room" phx-change="update_room" class="mt-4 space-y-4">
            <input
              type="text"
              name="room_code"
              placeholder="Enter room code"
              value={@room_code}
              class="w-full rounded-md border border-slate-300 bg-white px-4 py-2 text-lg tracking-widest uppercase text-slate-800 focus:border-emerald-500 focus:outline-none focus:ring-2 focus:ring-emerald-400 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-50 dark:focus:border-emerald-400 dark:focus:ring-emerald-400"
              autocomplete="off"
              maxlength="12"
            />
            <button
              type="submit"
              class="w-full rounded-md bg-slate-900 px-4 py-2 text-white hover:bg-slate-700 focus:outline-none focus:ring-2 focus:ring-slate-500 focus:ring-offset-2 disabled:opacity-60 dark:bg-slate-200 dark:text-slate-900 dark:hover:bg-slate-100 dark:focus:ring-slate-200 dark:focus:ring-offset-slate-900"
              phx-disable-with="Joining..."
            >
              <%= if @joining? do %>
                Joining...
              <% else %>
                Join Room
              <% end %>
            </button>
          </form>
        </div>

        <%= if @error do %>
          <p class="text-sm font-medium text-red-600 dark:text-red-400">{@error}</p>
        <% end %>
      </div>

      <div class="mt-10 rounded-xl border border-dashed border-emerald-400/60 bg-emerald-50/60 p-5 text-sm text-emerald-800 shadow-sm dark:border-emerald-400/40 dark:bg-emerald-900/20 dark:text-emerald-200">
        Built as an experiment in LiveView (Elixir + Phoenix) with GPT-5-Codex.
      </div>
    </div>
    """
  end
end
