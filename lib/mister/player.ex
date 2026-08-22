defmodule Mister.Player do
  @moduledoc """
  Jugador conocido por el sistema. `position`: 1=GK 2=DEF 3=MID 4=FWD.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "players" do
    field :mister_id, :integer
    field :name, :string
    field :position, :integer
    field :team_id, :integer
    field :season_avg, :float
    field :status, :string

    timestamps()
  end

  def changeset(player, attrs) do
    player
    |> cast(attrs, [:mister_id, :name, :position, :team_id, :season_avg, :status])
    |> validate_required([:mister_id, :name, :position])
    |> unique_constraint(:mister_id)
  end
end
