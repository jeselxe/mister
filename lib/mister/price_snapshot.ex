defmodule Mister.PriceSnapshot do
  @moduledoc """
  Snapshot diario propio de precio/cláusula de un jugador. Mister ya da el
  histórico (`values_chart`), pero guardar el nuestro permite cruzar decisiones
  tomadas con la evolución real posterior.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "price_snapshots" do
    belongs_to :player, Mister.Player
    field :price, :integer
    field :clause_value, :integer
    field :captured_at, :date

    timestamps()
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:player_id, :price, :clause_value, :captured_at])
    |> validate_required([:player_id, :price, :captured_at])
    |> unique_constraint([:player_id, :captured_at])
  end
end
