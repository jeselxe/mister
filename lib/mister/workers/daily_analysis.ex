defmodule Mister.Workers.DailyAnalysis do
  @moduledoc """
  Job diario de análisis (cron a las 7am, hora española).

  Es el **adaptador**: descarga mercado, plantilla, detalles de jugador, saldo y
  plantillas rivales; guarda el censo diario; delega el ensamblado del informe
  en `Mister.Analysis`; persiste el informe y lo emite por PubSub para que la
  vista se actualice sola.

  El sistema **no** puja ni compra: solo genera recomendaciones.
  """

  use Oban.Worker, queue: :mister, max_attempts: 3

  require Logger

  alias Mister.{
    Analysis,
    Client,
    MarketParser,
    PlayerRowParser,
    Reports,
    Rivals,
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

      details_by_id = fetch_details(market_players, my_squad)
      balance = fetch_balance(squad_summary)

      Logger.info(
        "DailyAnalysis: mercado=#{length(market_players)} plantilla=#{length(my_squad)} " <>
          "detalles=#{map_size(details_by_id)}"
      )

      rival_players = Rivals.clause_candidates(Analysis.own_user_id(my_squad, details_by_id))

      report =
        Analysis.build(%{
          market_players: market_players,
          my_squad: my_squad,
          squad_summary: squad_summary,
          details_by_id: details_by_id,
          balance: balance,
          rival_players: rival_players
        })

      persisted = Reports.persist!(report)

      Logger.info(
        "DailyAnalysis: informe generado (id #{persisted.id}) — " <>
          "compras=#{length(report.buy_recommendations)} ventas=#{length(report.sell_recommendations)} " <>
          "clausulazos=#{length(report.clause_targets)} once=#{length(report.best_lineup.players)} " <>
          "presupuesto=#{report.budget_summary.real_now}"
      )

      Phoenix.PubSub.broadcast(Mister.PubSub, "reports", {:new_report, persisted})
      :ok
    else
      {:error, reason} = error ->
        Logger.error("DailyAnalysis: no se pudo completar el análisis: #{inspect(reason)}")
        error
    end
  end

  ## Descarga

  defp fetch_details(market_players, my_squad) do
    (market_players ++ my_squad)
    |> Enum.map(& &1.player_id)
    |> Enum.uniq()
    |> Task.async_stream(&fetch_detail/1, max_concurrency: 4, timeout: 30_000)
    |> Enum.flat_map(fn
      {:ok, detail} when is_map(detail) -> [detail]
      _ -> []
    end)
    |> Map.new(&{player_id(&1), &1})
  end

  defp fetch_detail(id) do
    case Client.player_detail(id) do
      {:ok, detail} ->
        detail

      {:error, reason} ->
        Logger.warning("DailyAnalysis: detalle de jugador #{id} falló: #{inspect(reason)}")
        nil
    end
  end

  # Saldo real desde el estado embebido de la web; si falla, cae al texto de
  # /team (o 0).
  defp fetch_balance(squad_summary) do
    case Client.fetch_balance() do
      {:ok, %{current: current}} ->
        current

      {:error, reason} ->
        Logger.warning("DailyAnalysis: sin saldo (#{inspect(reason)}); uso fallback")
        squad_summary.balance || 0
    end
  end

  defp player_id(%{"player" => %{"id" => id}}) when not is_nil(id), do: id
  defp player_id(%{"id" => id}), do: id
  defp player_id(_), do: nil
end
