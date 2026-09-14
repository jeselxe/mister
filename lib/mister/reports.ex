defmodule Mister.Reports do
  @moduledoc """
  Construcción y persistencia del informe diario.

  `build/1` es puro: convierte los datos ya calculados (presupuesto,
  candidatos, valoraciones, clausulazos, alineación) en el mapa del informe.
  Cruza las fuentes entre sí:

    * las **pujas** solo se sugieren para jugadores con recorrido de reventa
      suficiente (o ratio puntos/precio excelente); el resto se muestra como
      "seguir" sin importe de puja.
    * un jugador **en venta** que entra en el mejor once deja de ser venta y
      pasa a "retirar de la venta" (sale también en las alertas).

  `persist!/1` guarda el informe del día (idempotente por fecha) y regenera
  el checklist de acciones (`report_actions`), preservando el estado
  (done/dismissed) de las tareas que ya estaban marcadas.
  """

  import Ecto.Query

  alias Mister.{DailyReport, Player, ReportAction, Repo, SaleEstimator, Valuation}

  @kind_priority ["clause", "buy", "sell", "unsell", "list", "lineup_change"]
  @max_sell_hints 6
  # Mister solo deja tener 5 jugadores en venta a la vez.
  @max_listed 5

  ## Build

  @doc """
  Construye el mapa del informe diario a partir de los datos calculados.

  Claves esperadas: `:budget`, `:buy_candidates`, `:valuations`,
  `:clause_targets`, `:lineup`, `:squad_summary`, `:my_squad`.
  """
  def build(%{budget: budget} = input) do
    my_squad = Map.get(input, :my_squad, [])
    squad_summary = Map.get(input, :squad_summary, %{})
    buy_candidates = Map.get(input, :buy_candidates, [])
    valuations = Map.get(input, :valuations, %{})
    clause_targets = Map.get(input, :clause_targets, [])
    lineup = Map.get(input, :lineup, %{})

    buy_recommendations = buy_recommendations(buy_candidates, budget, valuations)
    sell_recommendations = sell_recommendations(my_squad, lineup, valuations)
    sale_slots = sale_slots(my_squad, lineup)
    sell_hints = sell_hints(my_squad, lineup, valuations, sale_slots.free)

    %{
      report_date: Date.utc_today(),
      budget_summary: %{
        balance: squad_summary[:balance],
        total_value: squad_summary[:total_value],
        real_now: budget.real_now,
        real_projected: budget.real_projected,
        bid_allowed_now: budget.bid_allowed_now,
        bid_allowed_projected: budget.bid_allowed_projected,
        bid_rule: to_string(budget.bid_rule),
        sale_slots: %{
          listed: sale_slots.listed,
          max: sale_slots.max,
          free: sale_slots.free
        }
      },
      buy_recommendations: buy_recommendations,
      sell_recommendations: sell_recommendations,
      sell_hints: sell_hints,
      clause_targets: clause_targets,
      best_lineup: lineup,
      alerts: build_alerts(budget, lineup, clause_targets, sell_recommendations)
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

    # Recargamos para que las columnas JSONB vuelvan con claves string (como en
    # `latest/0`): la vista y el PubSub siempre leen el informe serializado.
    report = Repo.get!(DailyReport, report.id)
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

  ## Recomendaciones

  # Pujas: separa "pujar" (con importe) de "solo seguir". Las pujas van primero
  # y, dentro de cada grupo, por ganancia proyectada descendente.
  defp buy_recommendations(buy_candidates, budget, valuations) do
    buy_candidates
    |> Enum.map(&buy_recommendation(&1, budget, valuations))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(
      fn rec ->
        {bid_rank(rec.recommendation), -(rec.potential_gain_pct || -999.0)}
      end,
      :asc
    )
  end

  defp bid_rank("bid"), do: 0
  defp bid_rank(_), do: 1

  defp buy_recommendation(row, budget, valuations) do
    valuation = Map.get(valuations, row.player_id) || Valuation.from_detail(%{}, row.price)
    pts_per_million = pts_per_million(row)
    resale = valuation.resale_range

    # La puja es el coste real de la operación: la ganancia se mide contra ella.
    bid = base_bid(row.price, budget.bid_allowed_now, resale.expected)

    recommendation =
      Valuation.recommendation(valuation, row.price,
        bid: bid,
        affordable?: affordable?(row.price, budget.bid_allowed_now),
        pts_per_million: pts_per_million,
        avg: row.season_avg
      )

    # El coste real es la puja (precio + 5%, acotada); la ganancia se muestra
    # siempre contra ese importe, no contra el precio de salida.
    cost = if is_integer(bid), do: bid, else: row.price

    %{
      player_id: row.player_id,
      name: row.name,
      position: row.position,
      price: row.price,
      season_avg: row.season_avg,
      total_points: valuation[:total_points],
      pts_per_million: pts_per_million,
      trend: to_string(row.trend || :flat),
      growth_1d: valuation.growth_1d,
      growth_7d: valuation.growth_7d,
      growth_30d: valuation.growth_30d,
      projected_value: valuation.projected_value,
      resale_range: resale,
      expected_resale: resale.expected,
      cost: cost,
      potential_gain: Valuation.gain(resale.expected, cost),
      potential_gain_pct: Valuation.gain_pct(resale.expected, cost),
      potential_gain_pessimistic: Valuation.gain(resale.pessimistic, cost),
      potential_gain_optimistic: Valuation.gain(resale.optimistic, cost),
      recommendation: to_string(recommendation),
      source: source(row),
      seller_name: seller_label(row),
      suggested_bid: if(recommendation == :bid, do: bid, else: nil)
    }
  end

  # Ventas: cruza "en venta" con el mejor once. Un titular no se vende; se
  # marca con verdict "keep" para que el checklist pida retirarlo del mercado.
  defp sell_recommendations(my_squad, lineup, valuations) do
    picked = MapSet.new(Map.get(lineup, :players, []), & &1.player_id)

    my_squad
    |> Enum.filter(&(&1.for_sale? && &1.price))
    |> Enum.map(fn row ->
      in_best_lineup? = MapSet.member?(picked, row.player_id)
      valuation = Map.get(valuations, row.player_id, %{})

      %{
        player_id: row.player_id,
        name: row.name,
        position: row.position,
        trend: to_string(row.trend || :flat),
        growth_7d: valuation[:growth_7d],
        projected_value: valuation[:projected_value],
        market_price: row.price,
        sale_range: SaleEstimator.expected_range(row.price),
        in_best_lineup: in_best_lineup?,
        verdict: if(in_best_lineup?, do: "keep", else: "sell")
      }
    end)
    |> Enum.sort_by(fn rec -> {sell_rank(rec.verdict), -(rec.market_price || 0)} end, :asc)
  end

  defp sell_rank("sell"), do: 0
  defp sell_rank(_), do: 1

  # Huecos de venta disponibles. Los jugadores ya listados que el informe manda
  # retirar (titulares, `keep`) liberan su hueco, así que se descuentan.
  defp sale_slots(my_squad, lineup) do
    picked = MapSet.new(Map.get(lineup, :players, []), & &1.player_id)
    listed = Enum.count(my_squad, & &1.for_sale?)
    keep = Enum.count(my_squad, &(&1.for_sale? and MapSet.member?(picked, &1.player_id)))

    %{listed: listed, max: @max_listed, keep: keep, free: max(@max_listed - (listed - keep), 0)}
  end

  # Pistas de a quién **poner en venta**: jugadores fuera del mejor once que
  # no puntúan y/o pierden valor. No entran los ya listados (esos van en
  # `sell_recommendations`) ni los titulares. `free_slots` limita cuántos se
  # pueden listar de verdad (Mister deja 5 en venta como máximo).
  defp sell_hints(my_squad, lineup, valuations, free_slots) do
    picked = MapSet.new(Map.get(lineup, :players, []), & &1.player_id)

    my_squad
    |> Enum.reject(&(&1.for_sale? or MapSet.member?(picked, &1.player_id)))
    |> Enum.map(&sell_hint(&1, valuations))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.sort_key)
    |> Enum.take(min(@max_sell_hints, free_slots))
    |> Enum.map(&Map.delete(&1, :sort_key))
  end

  defp sell_hint(row, valuations) do
    valuation = Map.get(valuations, row.player_id, %{})
    avg = row.season_avg || 0.0
    growth = valuation[:growth_7d]
    value = valuation[:value] || row.price

    case sell_hint_reason(avg, growth) do
      nil ->
        nil

      reason ->
        %{
          player_id: row.player_id,
          name: row.name,
          position: row.position,
          trend: to_string(row.trend || :flat),
          season_avg: row.season_avg,
          total_points: valuation[:total_points],
          growth_7d: growth,
          market_value: value,
          sale_range: value && SaleEstimator.expected_range(value),
          reason: reason,
          # Los más urgentes primero: mayor caída y menos puntos.
          sort_key: {growth || 0.0, avg}
        }
    end
  end

  defp sell_hint_reason(avg, growth) do
    cond do
      avg <= 0.0 and (is_nil(growth) or growth < 5.0) ->
        "no puntúa y no entra en tu once"

      is_number(growth) and growth < -5.0 ->
        "en caída: mejor vender antes de que baje más"

      avg < 2.5 and (is_nil(growth) or growth < 1.0) ->
        "sin sitio en el once y sin revalorización"

      true ->
        nil
    end
  end

  defp pts_per_million(%{season_avg: avg, price: price})
       when is_number(avg) and is_integer(price) and price > 0,
       do: Float.round(avg / (price / 1_000_000), 2)

  defp pts_per_million(_), do: nil

  ## Actions

  defp build_actions(report_map) do
    clause_actions =
      Enum.map(Map.get(report_map, :clause_targets, []), fn target ->
        %{
          kind: "clause",
          mister_id: target.player_id,
          player_name: target.name,
          description:
            "⚡ Clausulazo: #{target.name} por #{money(target.clause_price)}" <>
              owner_suffix(target.owner_name),
          suggested_amount: target.clause_price
        }
      end)

    buy_actions =
      report_map
      |> Map.get(:buy_recommendations, [])
      |> Enum.filter(&(&1.recommendation == "bid"))
      |> Enum.map(fn rec ->
        %{
          kind: "buy",
          mister_id: rec.player_id,
          player_name: rec.name,
          description: "Pujar por #{rec.name}" <> bid_suffix(rec.suggested_bid),
          suggested_amount: rec.suggested_bid
        }
      end)

    sell_actions =
      report_map
      |> Map.get(:sell_recommendations, [])
      |> Enum.filter(&(&1.verdict == "sell"))
      |> Enum.map(fn rec ->
        %{
          kind: "sell",
          mister_id: rec.player_id,
          player_name: rec.name,
          description: "Vender #{rec.name} (oferta esperada #{money(rec.sale_range.expected)})",
          suggested_amount: rec.sale_range.expected
        }
      end)

    unsell_actions =
      report_map
      |> Map.get(:sell_recommendations, [])
      |> Enum.filter(& &1.in_best_lineup)
      |> Enum.map(fn rec ->
        %{
          kind: "unsell",
          mister_id: rec.player_id,
          player_name: rec.name,
          description: "Retirar de la venta a #{rec.name} (titular en tu mejor once)"
        }
      end)

    list_actions =
      report_map
      |> Map.get(:sell_hints, [])
      |> Enum.map(fn hint ->
        %{
          kind: "list",
          mister_id: hint.player_id,
          player_name: hint.name,
          description: "Poner en venta a #{hint.name} (#{hint.reason})",
          suggested_amount: hint.sale_range && hint.sale_range.expected
        }
      end)

    lineup_actions = lineup_actions(report_map)

    (clause_actions ++
       buy_actions ++ sell_actions ++ unsell_actions ++ list_actions ++ lineup_actions)
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

  defp owner_suffix(nil), do: ""
  defp owner_suffix(""), do: ""
  defp owner_suffix(name), do: " (de #{name})"

  defp affordable?(_price, :unlimited), do: true
  defp affordable?(price, cap) when is_integer(cap), do: not is_nil(price) and price <= cap
  defp affordable?(_price, _cap), do: false

  # Banca = sin propietario (data-owner="0") o vendedor "Libre"/"Mister".
  # Cualquier otro caso es un listado de usuario.
  defp source(%{owner_id: owner, seller_name: seller}) do
    if owner in [nil, "0"] and seller in [nil, "", "Libre", "Mister"],
      do: "banca",
      else: "usuario"
  end

  # Nombre del vendedor solo para listados de usuario (en banca es irrelevante).
  defp seller_label(%{owner_id: owner, seller_name: seller}) do
    if owner in [nil, "0"] and seller in [nil, "", "Libre", "Mister"], do: nil, else: seller
  end

  # Puja base: precio + 5% para ganar la puja, sin pasar del máximo de la liga
  # ni de la reventa esperada (no se puja por encima de lo que se espera
  # recuperar). El importe final solo se propone si la recomendación es `:bid`.
  defp base_bid(nil, _cap, _resale), do: nil

  defp base_bid(price, cap, resale),
    do: (price + div(price, 20)) |> min_cap(cap) |> min_cap(resale)

  defp min_cap(bid, limit) when is_integer(limit), do: min(bid, limit)
  defp min_cap(bid, _limit), do: bid

  ## Alerts

  defp build_alerts(budget, lineup, clause_targets, sell_recommendations) do
    [
      red_budget_alert(budget),
      lineup_alert(lineup),
      clause_alert(clause_targets),
      sale_conflict_alert(sell_recommendations)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp red_budget_alert(budget) do
    if is_integer(budget.real_now) and budget.real_now < 0 do
      "🚨 PRESUPUESTO EN ROJO: si sigues en negativo cuando arranca la jornada, NO PUNTÚAS. Vende o ajusta ya."
    end
  end

  defp lineup_alert(lineup) do
    if lineup[:formation] == nil do
      "No se pudo completar un once válido: faltan jugadores disponibles por demarcación."
    end
  end

  defp clause_alert([]), do: nil

  defp clause_alert(clause_targets) do
    "⚡ #{length(clause_targets)} clausulazo(s) pagables detectados: son compra inmediata, primero que llega se lo lleva."
  end

  defp sale_conflict_alert(sell_recommendations) do
    conflicts = Enum.filter(sell_recommendations, & &1.in_best_lineup)

    case conflicts do
      [] ->
        nil

      list ->
        names = Enum.map_join(list, ", ", & &1.name)

        "🔄 En venta pero titulares en tu mejor once: #{names}. Retíralos del mercado o perderás sus puntos."
    end
  end

  ## Helpers

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
