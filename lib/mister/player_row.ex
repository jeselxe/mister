defmodule Mister.PlayerRow do
  @moduledoc """
  Fila de jugador extraída del HTML de `/market` o `/team`.

  El `<li>` de un jugador es prácticamente idéntico en ambas páginas, por eso
  `Mister.MarketParser` y `Mister.PlayerRowParser` comparten esta estructura.
  """

  @enforce_keys [:player_id, :name]
  defstruct [
    :player_id,
    :name,
    :position,
    :team_logo_url,
    :price,
    :clause_value,
    :trend,
    :season_avg,
    :matchday_points,
    :owner_id,
    :seller_name,
    hot_clause?: false,
    in_lineup?: false,
    for_sale?: false
  ]

  @type t :: %__MODULE__{
          player_id: integer(),
          name: String.t(),
          position: integer() | nil,
          team_logo_url: String.t() | nil,
          price: integer() | nil,
          clause_value: integer() | nil,
          trend: :up | :down | :flat | nil,
          season_avg: float() | nil,
          matchday_points: float() | nil,
          owner_id: String.t() | nil,
          seller_name: String.t() | nil,
          hot_clause?: boolean(),
          in_lineup?: boolean(),
          for_sale?: boolean()
        }
end

# Los informes guardan filas de jugador en columnas JSONB; se serializa el
# struct completo (incluye claves dinámicas como :expected_points/:is_captain
# que añade LineupOptimizer).
defimpl Jason.Encoder, for: Mister.PlayerRow do
  def encode(value, opts) do
    value
    |> Map.from_struct()
    |> Jason.Encoder.encode(opts)
  end
end
