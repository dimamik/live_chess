defmodule LiveChess.Repo.Migrations.CreateGamesTable do
  use Ecto.Migration

  def change do
    create table(:games, primary_key: false) do
      add :room_id, :string, primary_key: true
      add :state, :binary, null: false
      add :status, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
