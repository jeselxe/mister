defmodule Mister.MarketParser do
  @moduledoc """
  Parser del listado de mercado (`POST /market`).

  El mercado mezcla dos secciones:

    * jugadores libres (sin propietario) — candidatos a puja
    * jugadores de rivales clausulables — candidatos a clausulazo

  Ambas usan el mismo `<li>` que `/team`, así que delega fila a fila en
  `Mister.PlayerRowParser`.
  """

  alias Mister.PlayerRowParser

  @doc "Todas las filas visibles del mercado (libres + clausulables)."
  def parse(html) when is_binary(html) do
    PlayerRowParser.parse_all(html)
  end

  def parse(_), do: []

  @doc "Solo jugadores sin propietario (puja de mercado)."
  def free_agents(html), do: html |> parse() |> Enum.filter(&is_nil(&1.owner_id))

  @doc "Solo jugadores con propietario y cláusula conocida (clausulazos)."
  def clauseable(html) do
    html
    |> parse()
    |> Enum.filter(&(&1.owner_id && &1.clause_value))
  end
end
