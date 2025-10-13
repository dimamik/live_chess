defmodule LiveChess.Games.GameRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:room_id, :string, autogenerate: false}
  schema "games" do
    field(:state, :binary)
    field(:status, :string)

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:room_id, :state, :status])
    |> validate_required([:room_id, :state, :status])
    |> unique_constraint(:room_id, name: :games_pkey)
  end
end
