defmodule Mister.Reports do
  @moduledoc """
  Construcción y persistencia del informe diario.

  `build/1` es puro: convierte los datos ya calculados (presupuesto,
  candidatos, clausulazos, alineación) en el mapa del informe, incluyendo las
  alertas (la de mayor prioridad es el presupuesto en rojo: si sigues en
  negativo cuando arranca la jornada, no puntúas esa jornada).

  `persist!/1` guarda el informe del día (idempotente por fecha) y regenera
  el checklist de acciones (`report_actions`), preservando el estado
  (done/dismissed) de las tareas que ya estaban marcadas.
  """

  import Ecto.Query

  alias Mister.{DailyReport, Player, ReportAction, Repo, SaleEstimator}

  @kind_priority ["clause", "buy", "sell", "lineup_change"]

  ## Build

  @doc """
  Construye el mapa del informe diario a partir de los datos calculados.

  Claves esperadas: `:budget`, `:buy_candidates`, `:clause_targets`,
  `:lineup`, `:squad_summary`, `:my_squad`.
  """
  def build(%{budget: budget} = input) do
    my_squad = Map.get(input, :my_squad, [])
    squad_summary = Map.get(input, :squad_summary, %{})
    buy_candidates = Map.get(input, :buy_candidates, [])
    clause_targets = Map.get(input, :clause_targets, [])
    lineup = Map.get(input, :lineup, %{})

    sell_recommendations = sell_recommendations(my_squad)
    buy_recommendations = buy_recommendations(buy_candidates, budget)

    %{
      report_date: Date.utc_today(),
      budget_summary: %{
        balance: squad_summary[:balance],
        total_value: squad_summary[:total_value],
        real_now: budget.real_now,
        real_projected: budget.real_projected,
        bid_allowed_now: budget.bid_allowed_now,
        bid_allowed_projected: budget.bid_allowed_projected,
        bid_rule: to_string(budget.bid_rule)
      },
      buy_recommendations: buy_recommendations,
      sell_recommendations: sell_recommendations,
      clause_targets: clause_targets,
      best_lineup: lineup,
      alerts: build_alerts(budget, lineup, clause_targets)
    }
  end

  ## Persist

  @doc """
  Guarda el informe del día y su checklist. Idempotente por fecha: si ya hay
  informe para hoy lo actualiza y regenera las acciones conservando el estado
  de las que coinciden (kind + player + descripción).
  """
  def persist!(report_map) do
    date = report_map.report_date

    previous_statuses =
      case Repo.one(from r in DailyReport, where: r.report_date == ^date, preload: :actions) do
        nil ->
          %{}

        existing ->
          Map.new(existing.actions, fn a ->
            {{a.kind, a.player_id, a.description}, a.status}
          end)
      end

    report = upsert_report!(date, report_map)
    Repo.delete_all(from a in ReportAction, where: a.daily_report_id == ^report.id)

    actions =
      report_map
      |> build_actions()
      |> Enum.map(fn attrs ->
        attrs =
          attrs
          |> Map.put(:daily_report_id, report.id)
          |> Map.put(:player_id, player_db_id(attrs[:mister_id]))
          |> Map.delete(:mister_id)

        status =
          Map.get(previous_statuses, {attrs.kind, attrs.player_id, attrs.description}, "pending")

        attrs = Map.put_new(attrs, :status, status)

        %ReportAction{}
        |> ReportAction.changeset(attrs)
        |> Repo.insert!()
      end)

    %{report | actions: actions}
  end

  @doc "Último informe guardado, con sus acciones."
  def latest do
    DailyReport
    |> order_by(desc: :report_date)
    |> limit(1)
    |> preload(:actions)
    |> Repo.one()
  end

  ## Internals

  defp upsert_report!(date, report_map) do
    attrs = Map.delete(report_map, :report_date)

    case Repo.one(from r in DailyReport, where: r.report_date == ^date) do
      nil ->
        %DailyReport{}
        |> DailyReport.changeset(Map.put(attrs, :report_date, date))
        |> Repo.insert!()

      existing ->
        existing
        |> DailyReport.changeset(attrs)
        |> Repo.update!()
    end
  end

  defp build_actions(report_map) do
    clause_actions =
      Enum.map(Map.get(report_map, :clause_targets, []), fn target ->
        %{
          kind: "clause",
          mister_id: target.player_id,
          description: "⚡ Clausulazo: #{target.name} por #{money(target.clause_price)}",
          suggested_amount: target.clause_price
        }
      end)

    buy_actions =
      Enum.map(Map.get(report_map, :buy_recommendations, []), fn rec ->
        %{
          kind: "buy",
          mister_id: rec.player_id,
          description: "Pujar por #{rec.name}" <> bid_suffix(rec.suggested_bid),
          suggested_amount: rec.suggested_bid
        }
      end)

    sell_actions =
      Enum.map(Map.get(report_map, :sell_recommendations, []), fn rec ->
        %{
          kind: "sell",
          mister_id: rec.player_id,
          description: "Vender #{rec.name} (oferta esperada #{money(rec.sale_range.expected)})",
          suggested_amount: rec.sale_range.expected
        }
      end)

    lineup_actions = lineup_actions(report_map)

    (clause_actions ++ buy_actions ++ sell_actions ++ lineup_actions)
    |> Enum.sort_by(&kind_index(&1.kind))
  end

  defp kind_index(kind),
    do: Enum.find_index(@kind_priority, &(&1 == kind)) || length(@kind_priority)

  defp lineup_actions(%{best_lineup: %{formation: formation}} = report_map)
       when not is_nil(formation) do
    picked_ids = MapSet.new(report_map.best_lineup.players, & &1.player_id)

    out_of_xi =
      Enum.filter(
        Map.get(report_map, :my_squad, []),
        &(&1.in_lineup? and not MapSet.member?(picked_ids, &1.player_id))
      )

    captain = Enum.find(report_map.best_lineup.players, & &1.is_captain)

    if out_of_xi != [] do
      [
        %{
          kind: "lineup_change",
          description:
            "Alinear #{formation} con capitán #{captain_name(captain)} (sacar: #{Enum.map_join(out_of_xi, ", ", & &1.name)})"
        }
      ]
    else
      []
    end
  end

  defp lineup_actions(_), do: []

  defp captain_name(nil), do: "?"
  defp captain_name(captain), do: captain.name

  defp bid_suffix(nil), do: ""
  defp bid_suffix(amount), do: " (hasta #{money(amount)})"

  defp sell_recommendations(my_squad) do
    my_squad
    |> Enum.filter(&(&1.for_sale? && &1.price))
    |> Enum.map(fn row ->
      %{
        player_id: row.player_id,
        name: row.name,
        market_price: row.price,
        sale_range: SaleEstimator.expected_range(row.price)
      }
    end)
  end

  defp buy_recommendations(buy_candidates, budget) do
    buy_candidates
    |> Enum.filter(&affordable?(&1.price, budget.bid_allowed_now))
    |> Enum.map(fn row ->
      %{
        player_id: row.player_id,
        name: row.name,
        price: row.price,
        season_avg: row.season_avg,
        trend: to_string(row.trend || :flat),
        # banca = sin propietario conocido; usuario = listado por un rival
        source: if(row.owner_id in [nil, "0"], do: "banca", else: "usuario"),
        suggested_bid: suggested_bid(row.price, budget.bid_allowed_now)
      }
    end)
  end

  defp affordable?(_price, :unlimited), do: true
  defp affordable?(price, cap) when is_integer(cap), do: not is_nil(price) and price <= cap
  defp affordable?(_price, _cap), do: false

  # Puja sugerida: precio + 5%, sin pasar nunca del máximo permitido por la liga.
  defp suggested_bid(nil, _cap), do: nil
  defp suggested_bid(price, :unlimited), do: price + div(price, 20)
  defp suggested_bid(price, cap) when is_integer(cap), do: min(price + div(price, 20), cap)
  defp suggested_bid(_price, _cap), do: nil

  defp build_alerts(budget, lineup, clause_targets) do
    alerts = []

    alerts =
      if is_integer(budget.real_now) and budget.real_now < 0 do
        [
          "🚨 PRESUPUESTO EN ROJO: si sigues en negativo cuando arranca la jornada, NO PUNTÚAS. Vende o ajusta ya."
          | alerts
        ]
      else
        alerts
      end

    alerts =
      if lineup[:formation] == nil do
        [
          "No se pudo completar un once válido: faltan jugadores disponibles por demarcación."
          | alerts
        ]
      else
        alerts
      end

    alerts =
      if clause_targets != [] do
        [
          "⚡ #{length(clause_targets)} clausulazo(s) pagables detectados: son compra inmediata, primero que llega se lo lleva."
          | alerts
        ]
      else
        alerts
      end

    Enum.reverse(alerts)
  end

  defp player_db_id(nil), do: nil

  defp player_db_id(mister_id) do
    case Repo.get_by(Player, mister_id: mister_id) do
      nil -> nil
      player -> player.id
    end
  end

  defp money(nil), do: "?"
  defp money(n) when is_integer(n), do: format_money(n)
  defp money(n) when is_float(n), do: n |> trunc() |> format_money()

  defp format_money(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3, 3, [])
    |> Enum.join(".")
    |> String.reverse()
    |> Kernel.<>(" €")
  end
end
