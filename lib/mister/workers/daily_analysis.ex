defmodule Mister.Workers.DailyAnalysis do
  @moduledoc """
  Job diario de análisis (cron a las 7am, hora española).

  1. Descarga mercado y plantilla.
  2. Guarda el censo diario (jugadores, snapshots de precio, membresías).
  3. Pide el detalle (`/ajax/sw/players`) de **todo** el mercado y de **toda**
     la plantilla. Antes solo se pedía de candidatos "calientes", pero eso
     rompía dos cruces de datos: el filtro de lesión/sanción no cubría a los
     titulares y los clausulazos dependían de detalles que nunca se cargaban.
  4. Recorre las **plantillas rivales** (`Mister.Rivals`: `/standings` +
     `/ajax/sw/users`). Un clausulazo se puede pagar sobre cualquier jugador
     de un rival, no solo sobre los que están en venta en `/market`.
  5. Calcula presupuesto, valoraciones (crecimiento + reventa proyectada),
     clausulazos pagables y alineación óptima.
  6. Cruza todo al construir el informe: las ventas que son titulares en el
     mejor once dejan de ser "vender" y pasan a "retirar de la venta".
  7. Persiste el informe y lo emite por PubSub para que la vista se actualice.

  El sistema **no** puja ni compra: solo genera recomendaciones.
  """

  use Oban.Worker, queue: :mister, max_attempts: 3

  require Logger

  alias Mister.{
    BudgetEngine,
    ClauseDetector,
    Client,
    LineupOptimizer,
    MarketParser,
    PlayerRowParser,
    Reports,
    Rivals,
    SaleEstimator,
    Store,
    Valuation
  }

  @impl Oban.Worker
  def perform(_job) do
    with {:ok, market_html} <- Client.fetch_market(),
         {:ok, team_html} <- Client.fetch_team() do
      market_players = MarketParser.parse(market_html)
      my_squad = PlayerRowParser.parse_all(team_html)
      squad_summary = PlayerRowParser.parse_squad_summary(team_html)

      Store.record_daily_census(market_players, my_squad, squad_summary)

      # El mercado incluye también nuestros propios jugadores en venta. No son
      # candidatos a fichaje ni a clausulazo: los sacamos del análisis (pero se
      # mantienen en el censo y en las recomendaciones de venta).
      own_ids = MapSet.new(my_squad, & &1.player_id)
      market_players = Enum.reject(market_players, &MapSet.member?(own_ids, &1.player_id))

      buy_candidates = Enum.filter(market_players, &interesting?/1)

      market_ids = market_players |> Enum.map(& &1.player_id) |> Enum.uniq()
      squad_ids = my_squad |> Enum.map(& &1.player_id) |> Enum.uniq()

      details_by_id =
        (market_ids ++ squad_ids)
        |> Enum.uniq()
        |> fetch_details()
        |> Map.new(&{player_id(&1), &1})

      # Clausulazos: solo rivales (la cláusula de un jugador propio no se
      # puede pagar para ficharlo). La alineación sí usa los detalles propios.
      market_details = details_for(market_ids, details_by_id)
      squad_details = details_for(squad_ids, details_by_id)

      Logger.info(
        "DailyAnalysis: mercado=#{length(market_players)} plantilla=#{length(my_squad)} " <>
          "candidatos=#{length(buy_candidates)} detalles=#{map_size(details_by_id)}"
      )

      sale_candidates = sale_candidates(my_squad)
      total_value = squad_summary.total_value || 0

      # Saldo real desde el estado embebido de la web; si falla, cae al
      # texto de /team (o 0).
      balance =
        case Client.fetch_balance() do
          {:ok, %{current: current}} ->
            current

          {:error, reason} ->
            Logger.warning("DailyAnalysis: sin saldo (#{inspect(reason)}); uso fallback")
            squad_summary.balance || 0
        end

      budget = BudgetEngine.available_budget(balance, total_value, sale_candidates)

      # Los clausulazos se pagan con saldo real (nunca con el bonus de puja) y
      # se pueden ejecutar sobre CUALQUIER jugador rival, esté o no en venta:
      # por eso se recorren las plantillas rivales (`Mister.Rivals`) además del
      # mercado, y se descartan los jugadores propios.
      clause_candidates =
        market_details
        |> Kernel.++(Rivals.clause_candidates(my_user_id(squad_details)))
        |> Enum.reject(&(player_id(&1) in own_ids))

      clause_targets = ClauseDetector.find_opportunities(clause_candidates, budget.real_now)
      lineup = LineupOptimizer.best_lineup(my_squad, squad_details)

      valuations = build_valuations(market_players, my_squad, details_by_id)

      report =
        Reports.build(%{
          budget: budget,
          buy_candidates: buy_candidates,
          valuations: valuations,
          clause_targets: clause_targets,
          lineup: lineup,
          squad_summary: squad_summary,
          my_squad: my_squad
        })

      persisted = Reports.persist!(report)

      Logger.info(
        "DailyAnalysis: informe generado (id #{persisted.id}) — " <>
          "compras=#{length(report.buy_recommendations)} ventas=#{length(report.sell_recommendations)} " <>
          "clausulazos=#{length(report.clause_targets)} once=#{length(report.best_lineup.players)} " <>
          "presupuesto=#{budget.real_now}"
      )

      Phoenix.PubSub.broadcast(Mister.PubSub, "reports", {:new_report, persisted})
      :ok
    else
      {:error, reason} = error ->
        Logger.error("DailyAnalysis: no se pudo completar el análisis: #{inspect(reason)}")
        error
    end
  end

  # Candidatos de mercado baratos de filtrar desde el HTML: tendencia al alza
  # o buen ratio puntos/precio (> 1.5 pts por millón). El detalle ya se pide
  # para todo el mercado (para los clausulazos), pero el informe solo muestra
  # estos como posibles fichajes.
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

  # Id de usuario propio: lo saca el `owner` de cualquiera de nuestros
  # jugadores (en la plantilla todos somos el propietario).
  defp my_user_id(details) do
    Enum.find_value(details, &get_in(&1, ["player", "owner", "id"]))
  end

  defp build_valuations(market_players, my_squad, details_by_id) do
    (market_players ++ my_squad)
    |> Enum.uniq_by(& &1.player_id)
    |> Map.new(fn row ->
      {row.player_id, Valuation.from_detail(Map.get(details_by_id, row.player_id), row.price)}
    end)
  end

  defp fetch_details(ids) do
    ids
    |> Task.async_stream(
      fn id ->
        case Client.player_detail(id) do
          {:ok, detail} ->
            detail

          {:error, reason} ->
            Logger.warning("DailyAnalysis: detalle de jugador #{id} falló: #{inspect(reason)}")
            nil
        end
      end,
      max_concurrency: 4,
      timeout: 30_000
    )
    |> Enum.flat_map(fn
      {:ok, detail} when is_map(detail) -> [detail]
      _ -> []
    end)
  end

  defp player_id(%{"player" => %{"id" => id}}) when not is_nil(id), do: id
  defp player_id(%{"id" => id}), do: id
  defp player_id(_), do: nil
end
