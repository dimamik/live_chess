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
     |> assign(:joining?, false)}
  end

  @impl true
  def handle_event("create_room", _params, socket) do
    socket = assign(socket, creating?: true, error: nil)

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

  def handle_event("update_room", %{"room_code" => room_code}, socket) do
    {:noreply, assign(socket, :room_code, normalize_room(room_code))}
  end

  def handle_event("join_room", _params, socket) do
    room_id = socket.assigns.room_code

    cond do
      room_id == "" ->
        {:noreply, assign(socket, :error, "Enter a room code to join.")}

      true ->
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl px-6 py-12">
      <h1 class="text-3xl font-semibold text-slate-900">Live Chess</h1>
      <p class="mt-2 text-slate-600">Create a room to play or join one with a room code.</p>

      <div class="mt-8 space-y-6">
        <button
          type="button"
          phx-click="create_room"
          phx-disable-with="Creating..."
          class="w-full rounded-md bg-emerald-600 px-4 py-3 text-lg font-medium text-white hover:bg-emerald-500 focus:outline-none focus:ring-2 focus:ring-emerald-400 focus:ring-offset-2 disabled:opacity-60"
        >
          <%= if @creating? do %>
            Creating room...
          <% else %>
            Create Room
          <% end %>
        </button>

        <div class="rounded-lg border border-slate-200 bg-white p-6 shadow-sm">
          <h2 class="text-xl font-semibold text-slate-800">Join a Room</h2>
          <form phx-submit="join_room" phx-change="update_room" class="mt-4 space-y-4">
            <input
              type="text"
              name="room_code"
              placeholder="Enter room code"
              value={@room_code}
              class="w-full rounded-md border border-slate-300 px-4 py-2 text-lg tracking-widest uppercase focus:border-emerald-500 focus:outline-none focus:ring-2 focus:ring-emerald-400"
              autocomplete="off"
              maxlength="12"
            />
            <button
              type="submit"
              class="w-full rounded-md bg-slate-900 px-4 py-2 text-white hover:bg-slate-700 focus:outline-none focus:ring-2 focus:ring-slate-500 focus:ring-offset-2 disabled:opacity-60"
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
          <p class="text-sm font-medium text-red-600">{@error}</p>
        <% end %>
      </div>

      <div class="mt-10 rounded-xl border border-dashed border-emerald-400/60 bg-emerald-50/60 p-5 text-sm text-emerald-800 shadow-sm dark:border-emerald-400/40 dark:bg-emerald-900/20 dark:text-emerald-200">
        Built as an experiment in LiveView (Elixir + Phoenix) with GPT-5-Codex.
      </div>
    </div>
    """
  end
end
