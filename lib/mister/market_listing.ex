defmodule Mister.MarketListing do
  @moduledoc "Listado diario del mercado (jugadores libres y en subasta)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "market_listings" do
    belongs_to :player, Mister.Player
    field :price, :integer
    field :is_public, :boolean, default: true
    field :ends_at, :utc_datetime
    field :seen_at, :date

    timestamps()
  end

  def changeset(listing, attrs) do
    listing
    |> cast(attrs, [:player_id, :price, :is_public, :ends_at, :seen_at])
    |> validate_required([:player_id, :price, :seen_at])
  end
end
