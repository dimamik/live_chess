defmodule LiveChess.Games.Storage do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias LiveChess.Repo
  alias LiveChess.Games.GameRecord

  @doc """
  Persist the latest in-memory state for a game.
  """
  def persist_state(%{room_id: room_id} = state) when is_binary(room_id) do
    encoded = :erlang.term_to_binary(state)
    status = status_to_string(Map.get(state, :status))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      room_id: room_id,
      state: encoded,
      status: status
    }

    changeset = GameRecord.changeset(%GameRecord{}, attrs)

    Repo.insert(changeset,
      on_conflict: [
        set: [state: encoded, status: status, updated_at: now]
      ],
      conflict_target: [:room_id]
    )
  end

  @doc """
  Load a previously persisted game state.
  """
  def fetch_state(room_id) when is_binary(room_id) do
    case Repo.get(GameRecord, room_id) do
      nil -> :error
      record -> decode_record(record)
    end
  end

  def list_room_ids do
    Repo.all(from(r in GameRecord, select: r.room_id))
  end

  def list_room_ids(since_datetime) when is_struct(since_datetime, DateTime) do
    Repo.all(from(r in GameRecord, where: r.updated_at >= ^since_datetime, select: r.room_id))
  end

  def exists?(room_id) when is_binary(room_id) do
    Repo.exists?(from(r in GameRecord, where: r.room_id == ^room_id))
  end

  def delete(room_id) when is_binary(room_id) do
    case Repo.get(GameRecord, room_id) do
      nil -> {:ok, :not_found}
      record -> Repo.delete(record)
    end
  end

  defp decode_record(%GameRecord{state: binary}) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    ArgumentError -> :error
  end

  defp status_to_string(status) when is_atom(status), do: Atom.to_string(status)
  defp status_to_string(status) when is_binary(status), do: status
  defp status_to_string(_status), do: "unknown"
end
