defmodule Mister.Analysis do
  @moduledoc """
  Ensamblado **puro** del informe diario a partir de los datos ya descargados.

  Recibe el mercado y la plantilla parseados, los detalles de jugador, el saldo
  y los jugadores de las plantillas rivales, y devuelve el mapa del informe que
  consume `Mister.Reports.persist!`. Sin HTTP ni base de datos: el worker
  (`Mister.Workers.DailyAnalysis`) es el adaptador que descarga, persiste y
  emite; aquí vive solo el ensamblado y las políticas que lo cruzan.
  """

  alias Mister.{
    BudgetEngine,
    ClauseDetector,
    LineupOptimizer,
    Reports,
    SaleEstimator,
    Valuation
  }

  @doc """
  Construye el informe a partir de:

    * `:market_players` — filas de `/market`
    * `:my_squad` — filas de `/team`
    * `:squad_summary` — `%{balance:, total_value:}` de `/team`
    * `:details_by_id` — detalle JSON por `mister_id`
    * `:balance` — saldo real disponible (entero)
    * `:rival_players` — candidatos de clausulazo de los rivales (`Mister.Rivals`)

  El mercado incluye nuestros propios jugadores en venta: se descartan del
  análisis (pero siguen en las recomendaciones de venta).
  """
  def build(input) do
    market_players = Map.get(input, :market_players, [])
    my_squad = Map.get(input, :my_squad, [])
    squad_summary = Map.get(input, :squad_summary, %{})
    details_by_id = Map.get(input, :details_by_id, %{})
    balance = Map.get(input, :balance, 0)
    rival_players = Map.get(input, :rival_players, [])

    own_ids = MapSet.new(my_squad, & &1.player_id)
    market_players = Enum.reject(market_players, &MapSet.member?(own_ids, &1.player_id))

    buy_candidates = Enum.filter(market_players, &interesting?/1)

    market_ids = market_players |> Enum.map(& &1.player_id) |> Enum.uniq()
    squad_ids = my_squad |> Enum.map(& &1.player_id) |> Enum.uniq()

    market_details = details_for(market_ids, details_by_id)
    squad_details = details_for(squad_ids, details_by_id)

    total_value = squad_summary[:total_value] || 0
    budget = BudgetEngine.available_budget(balance, total_value, sale_candidates(my_squad))

    # Los clausulazos se pagan con saldo real y valen sobre cualquier rival, no
    # solo sobre los que están en venta en el mercado; los propios no cuentan.
    clause_candidates =
      market_details
      |> Kernel.++(rival_players)
      |> Enum.reject(&(player_id(&1) in own_ids))

    clause_targets = ClauseDetector.find_opportunities(clause_candidates, budget.real_now)
    lineup = LineupOptimizer.best_lineup(my_squad, squad_details)
    valuations = build_valuations(market_players, my_squad, details_by_id)

    Reports.build(%{
      budget: budget,
      buy_candidates: buy_candidates,
      valuations: valuations,
      clause_targets: clause_targets,
      lineup: lineup,
      squad_summary: squad_summary,
      my_squad: my_squad
    })
  end

  @doc """
  Id de usuario propio, tomado del `owner` de cualquiera de nuestros jugadores
  (en la plantilla todos somos el propietario). El adaptador lo necesita para
  no pedir su propia plantilla al recorrer las rivales.
  """
  def own_user_id(my_squad, details_by_id) do
    Enum.find_value(my_squad, fn row ->
      get_in(details_by_id[row.player_id] || %{}, ["player", "owner", "id"])
    end)
  end

  ## Internals

  # Candidatos de mercado baratos de filtrar desde el HTML: tendencia al alza
  # o buen ratio puntos/precio (> 1.5 pts por millón).
  defp interesting?(player) do
    player.trend == :up or
      (player.season_avg != nil and player.price != nil and player.price > 0 and
         player.season_avg / (player.price / 1_000_000) > 1.5)
  end

  defp sale_candidates(my_squad) do
    my_squad
    |> Enum.filter(&(&1.for_sale? && &1.price))
    |> Enum.map(fn row ->
      %{
        player_id: row.player_id,
        expected_sale_price: SaleEstimator.expected_range(row.price).expected
      }
    end)
  end

  defp details_for(ids, details_by_id) do
    ids
    |> Enum.map(&Map.get(details_by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp build_valuations(market_players, my_squad, details_by_id) do
    (market_players ++ my_squad)
    |> Enum.uniq_by(& &1.player_id)
    |> Map.new(fn row ->
      {row.player_id, Valuation.from_detail(Map.get(details_by_id, row.player_id), row.price)}
    end)
  end

  defp player_id(%{"player" => %{"id" => id}}) when not is_nil(id), do: id
  defp player_id(%{"id" => id}), do: id
  defp player_id(_), do: nil
end
