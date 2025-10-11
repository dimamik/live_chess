defmodule LiveChess.GameSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias LiveChess.GameServer

  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_game(room_id) do
    child_spec = {GameServer, room_id}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:error, {:already_started, _pid}} -> {:ok, :already_started}
      other -> other
    end
  end
end
