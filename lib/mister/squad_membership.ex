defmodule Mister.SquadMembership do
  @moduledoc """
  Pertenencia diaria de un jugador a una plantilla ("me" | "rival").
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "squad_memberships" do
    belongs_to :player, Mister.Player
    field :owner_type, :string
    field :owner_mister_id, :string
    field :owner_name, :string
    field :in_lineup, :boolean, default: false
    field :for_sale, :boolean, default: false
    field :recorded_at, :date

    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [
      :player_id,
      :owner_type,
      :owner_mister_id,
      :owner_name,
      :in_lineup,
      :for_sale,
      :recorded_at
    ])
    |> validate_required([:player_id, :owner_type, :recorded_at])
    |> validate_inclusion(:owner_type, ["me", "rival"])
  end
end
