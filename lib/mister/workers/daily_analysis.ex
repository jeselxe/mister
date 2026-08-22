defmodule Mister.Workers.DailyAnalysis do
  @moduledoc """
  Job diario de análisis (cron a las 7am, hora española).

  1. Descarga mercado y plantilla.
  2. Guarda el censo diario (jugadores, snapshots de precio, membresías).
  3. Pide detalle (`/ajax/sw/players`) solo de candidatos "calientes":
     mercado con tendencia buena o ratio precio/puntos alto, y jugadores
     propios con cláusula caliente.
  4. Calcula presupuesto, clausulazos pagables y alineación óptima.
  5. Construye y persiste el informe, y lo emite por PubSub para que la
     vista se actualice sola.

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
    SaleEstimator,
    Store
  }

  @impl Oban.Worker
  def perform(_job) do
    with {:ok, market_html} <- Client.fetch_market(),
         {:ok, team_html} <- Client.fetch_team() do
      market_players = MarketParser.parse(market_html)
      my_squad = PlayerRowParser.parse_all(team_html)
      squad_summary = PlayerRowParser.parse_squad_summary(team_html)

      Store.record_daily_census(market_players, my_squad, squad_summary)

      buy_candidates = Enum.filter(market_players, &interesting?/1)
      hot_own_players = Enum.filter(my_squad, & &1.hot_clause?)

      Logger.info(
        "DailyAnalysis: mercado=#{length(market_players)} plantilla=#{length(my_squad)} " <>
          "candidatos=#{length(buy_candidates)} clausula_caliente=#{length(hot_own_players)}"
      )

      details =
        (buy_candidates ++ hot_own_players)
        |> Enum.map(& &1.player_id)
        |> Enum.uniq()
        |> fetch_details()

      sale_candidates = sale_candidates(my_squad)
      balance = squad_summary.balance || 0
      total_value = squad_summary.total_value || 0

      budget = BudgetEngine.available_budget(balance, total_value, sale_candidates)
      clause_targets = ClauseDetector.find_opportunities(details, budget.real_projected)
      lineup = LineupOptimizer.best_lineup(my_squad, details)

      report =
        Reports.build(%{
          budget: budget,
          buy_candidates: buy_candidates,
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
          "presupuesto=#{budget.real_projected}"
      )

      Phoenix.PubSub.broadcast(Mister.PubSub, "reports", {:new_report, persisted})
      :ok
    else
      {:error, reason} = error ->
        Logger.error("DailyAnalysis: no se pudo completar el análisis: #{inspect(reason)}")
        error
    end
  end

  # Candidatos de mercado baratos de filtrar: tendencia al alza o buen ratio
  # puntos/precio (> 1.5 pts por millón). El detalle JSON es una petición por
  # jugador, así que solo se pide para estos.
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
      max_concurrency: 3,
      timeout: 30_000
    )
    |> Enum.flat_map(fn
      {:ok, detail} when is_map(detail) -> [detail]
      _ -> []
    end)
  end
end
