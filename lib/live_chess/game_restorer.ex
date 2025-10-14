defmodule LiveChess.GameRestorer do
  @moduledoc false

  use GenServer

  alias LiveChess.{GameSupervisor, Games.Storage}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DateTime.utc_now()
    |> DateTime.add(-15 * 60, :second)
    |> Storage.list_room_ids()
    |> Enum.each(&GameSupervisor.start_game/1)

    {:ok, :ok}
  end
end
