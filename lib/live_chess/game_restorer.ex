defmodule LiveChess.GameRestorer do
  @moduledoc false

  use GenServer

  alias LiveChess.{GameSupervisor, Games.Storage}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Storage.list_room_ids()
    |> Enum.each(&GameSupervisor.start_game/1)

    {:ok, :ok}
  end
end
