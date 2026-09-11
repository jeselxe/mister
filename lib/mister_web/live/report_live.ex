defmodule MisterWeb.ReportLive do
  @moduledoc """
  Informe diario de análisis (sección 12 del spec).

  Muestra, en orden de prioridad:

    * aviso destacado si el presupuesto sigue en rojo (riesgo de no puntuar)
    * resumen de presupuesto (real vs. proyectado tras ventas)
    * clausulazos pagables (compra inmediata, urgencia alta)
    * fichajes recomendados y ventas con rango estimado
    * checklist de tareas del día (`report_actions`), marcable y persistente
    * alineación óptima visual con capitán y excluidos por lesión/sanción

  Se actualiza sola cuando termina el job diario vía `Phoenix.PubSub`.
  El usuario ejecuta las acciones manualmente en Mister: aquí solo marca
  qué ya ha hecho.
  """
  use MisterWeb, :live_view

  require Logger

  alias Mister.{Reports, Repo}
  alias Mister.Workers.DailyAnalysis
  alias MisterWeb.Components.FormationPitch

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mister.PubSub, "reports")
    end

    report = Reports.latest()

    socket =
      socket
      |> assign(:current_scope, nil)
      |> assign(:report, report)
      |> assign(:actions, actions_of(report))
      |> assign(:offers, [])
      |> assign(:offers_error, nil)

    socket =
      if connected?(socket) do
        load_offers(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info({:new_report, %Mister.DailyReport{} = report}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Nuevo informe disponible ✅")
     |> assign(:report, report)
     |> assign(:actions, actions_of(report))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Eventos del checklist

  @impl true
  def handle_event("complete_action", %{"id" => id}, socket) do
    {:noreply, update_action_status(socket, String.to_integer(id), "done")}
  end

  def handle_event("dismiss_action", %{"id" => id}, socket) do
    {:noreply, update_action_status(socket, String.to_integer(id), "dismissed")}
  end

  def handle_event("undo_action", %{"id" => id}, socket) do
    {:noreply, update_action_status(socket, String.to_integer(id), "pending")}
  end

  # Recarga las ofertas recibidas (botón de refresco).
  @impl true
  def handle_event("refresh_offers", _params, socket) do
    {:noreply, load_offers(socket)}
  end

  # Acepta una oferta real en Mister (acción sobre la cuenta).
  @impl true
  def handle_event("accept_offer", %{"id_bid" => id_bid, "amount" => amount}, socket) do
    case Mister.Client.accept_offer(String.to_integer(id_bid), String.to_integer(amount)) do
      {:ok, :accepted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Oferta aceptada ✅")
         |> load_offers()}

      {:error, reason} ->
        Logger.error("ReportLive: no se pudo aceptar la oferta: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "No se pudo aceptar la oferta")}
    end
  end

  # Deniega la oferta y mantiene el jugador a la escucha de nuevas ofertas.
  @impl true
  def handle_event("keep_on_sale", %{"id_market" => id_market}, socket) do
    case Mister.Client.keep_on_sale(String.to_integer(id_market)) do
      {:ok, :on_sale} ->
        {:noreply,
         socket
         |> put_flash(:info, "Mantenido en venta: seguirá escuchando ofertas 🔁")
         |> load_offers()}

      {:error, reason} ->
        Logger.error("ReportLive: no se pudo mantener en venta: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "No se pudo mantener en venta")}
    end
  end

  # Lanza el análisis bajo demanda (útil en dev o para re-analizar tras
  # fichar/vender manualmente). En producción corre también el cron de las 7am.
  def handle_event("run_analysis", _params, socket) do
    case Oban.insert(DailyAnalysis.new(%{})) do
      {:ok, _job} ->
        {:noreply,
         put_flash(socket, :info, "Análisis encolado: el informe se actualizará al terminar ⏳")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo encolar el análisis")}
    end
  end

  ## Helpers de plantilla

  defp load_offers(socket) do
    case Mister.Client.fetch_offers_received() do
      {:ok, offers} ->
        assign(socket, :offers, Enum.map(offers, &enrich_with_purchase_price/1))
        |> assign(:offers_error, nil)

      {:error, reason} ->
        Logger.warning("ReportLive: no se pudieron cargar las ofertas: #{inspect(reason)}")

        assign(socket, :offers, [])
        |> assign(:offers_error, reason)
    end
  end

  # Añade lo que pagamos por el jugador (detalle JSON → transfer.price) para
  # poder mostrar el balance real de la operación.
  defp enrich_with_purchase_price(offer) do
    case Mister.Client.player_detail(offer.player_id) do
      {:ok, %{"player" => %{"transfer" => %{"price" => paid}}}} when is_integer(paid) ->
        Map.put(offer, :paid_price, paid)

      _ ->
        Map.put(offer, :paid_price, nil)
    end
  end

  defp actions_of(nil), do: []
  defp actions_of(%{actions: actions}), do: actions || []

  defp update_action_status(socket, id, status) do
    action = Repo.get!(Mister.ReportAction, id)
    action = action |> Mister.ReportAction.changeset(%{status: status}) |> Repo.update!()

    actions =
      Enum.map(socket.assigns.actions, fn a ->
        if a.id == action.id, do: %{a | status: action.status}, else: a
      end)

    assign(socket, :actions, actions)
  end

  def pending?(%{status: "pending"}), do: true
  def pending?(_), do: false

  def done?(%{status: "done"}), do: true
  def done?(_), do: false

  def action_classes(action) do
    cond do
      done?(action) ->
        "group flex items-center gap-3 rounded-xl px-3 py-2.5 ring-1 transition bg-emerald-50 ring-emerald-200 opacity-70"

      action.status == "dismissed" ->
        "group flex items-center gap-3 rounded-xl px-3 py-2.5 ring-1 transition bg-slate-50 ring-slate-200 opacity-50"

      action.kind == "clause" ->
        "group flex items-center gap-3 rounded-xl px-3 py-2.5 ring-1 transition bg-amber-50 ring-amber-300"

      true ->
        "group flex items-center gap-3 rounded-xl px-3 py-2.5 ring-1 transition bg-white ring-slate-200 hover:bg-slate-50"
    end
  end

  def balance_classes(nil), do: "mt-1 text-xl font-black text-slate-900"

  def balance_classes(balance) when is_integer(balance) and balance < 0,
    do: "mt-1 text-xl font-black text-red-600"

  def balance_classes(_), do: "mt-1 text-xl font-black text-slate-900"

  @bid_rules %{
    "balance_plus_25" => "saldo + 25% equipo",
    "balance_plus_50" => "saldo + 50% equipo",
    "balance_only" => "solo saldo",
    "unlimited" => "sin límite"
  }

  def bid_rule_label(rule), do: Map.get(@bid_rules, rule, rule)

  def money(nil), do: "?"
  def money(n) when is_binary(n), do: n
  def money(n) when is_float(n), do: n |> trunc() |> money()

  def money(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3, 3, [])
    |> Enum.join(".")
    |> String.reverse()
    |> Kernel.<>(" €")
  end

  def pts(nil), do: "-"
  def pts(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  def pts(n) when is_integer(n), do: Integer.to_string(n)
  def pts(other), do: to_string(other)

  @doc "Borde del rango de reventa (con respaldo en la proyección esperada)."
  def resale_edge(rec, edge) do
    get_in(rec, ["resale_range", edge]) || rec["expected_resale"]
  end

  def trend_icon("up"), do: "hero-arrow-trending-up"
  def trend_icon("down"), do: "hero-arrow-trending-down"
  def trend_icon(_), do: "hero-arrow-long-right"

  # Chip de tendencia bien visible (verde/rojo/gris con flecha).
  def trend_classes("up"),
    do:
      "inline-flex items-center gap-0.5 rounded-md bg-emerald-100 px-1.5 py-0.5 text-[11px] font-black text-emerald-700 ring-1 ring-emerald-300"

  def trend_classes("down"),
    do:
      "inline-flex items-center gap-0.5 rounded-md bg-red-100 px-1.5 py-0.5 text-[11px] font-black text-red-700 ring-1 ring-red-300"

  def trend_classes(_),
    do:
      "inline-flex items-center gap-0.5 rounded-md bg-slate-100 px-1.5 py-0.5 text-[11px] font-bold text-slate-500 ring-1 ring-slate-200"

  def trend_label("up"), do: "alza"
  def trend_label("down"), do: "baja"
  def trend_label(_), do: "plano"

  @pos_labels %{1 => "PT", 2 => "DF", 3 => "MD", 4 => "DC"}
  def pos_label(pos) when is_integer(pos) and is_map_key(@pos_labels, pos),
    do: Map.get(@pos_labels, pos)

  def pos_label(pos) when is_binary(pos) do
    case Integer.parse(pos) do
      {p, _} -> pos_label(p)
      _ -> nil
    end
  end

  def pos_label(_), do: nil

  def pos_classes(pos_label) when pos_label in ["PT", "DF", "MD", "DC"],
    do: "rounded bg-slate-800 px-1.5 py-0.5 text-[10px] font-black tracking-wide text-white"

  def kind_icon("clause"), do: "hero-bolt"
  def kind_icon("buy"), do: "hero-shopping-bag"
  def kind_icon("sell"), do: "hero-banknotes"
  def kind_icon("unsell"), do: "hero-arrow-uturn-left"
  def kind_icon("list"), do: "hero-tag"
  def kind_icon("lineup_change"), do: "hero-arrows-right-left"
  def kind_icon(_), do: "hero-check-circle"

  def kind_label("clause"), do: "Clausulazo"
  def kind_label("buy"), do: "Pujar"
  def kind_label("sell"), do: "Vender"
  def kind_label("unsell"), do: "Retirar de la venta"
  def kind_label("list"), do: "Poner en venta"
  def kind_label("lineup_change"), do: "Alineación"
  def kind_label(_), do: "Tarea"

  @doc "¿La recomendación de fichaje conlleva una puja con importe?"
  def bid?(%{"recommendation" => "bid"}), do: true
  def bid?(_), do: false

  @doc "Porcentaje con signo, p. ej. `+6,3%` / `-2,1%`."
  def signed_pct(nil), do: nil

  def signed_pct(n) when is_number(n) do
    sign = if(n >= 0, do: "+", else: "")
    sign <> :erlang.float_to_binary(n * 1.0, decimals: 1) <> "%"
  end

  def signed_pct(other), do: to_string(other)

  def growth_classes(nil), do: "text-slate-400"
  def growth_classes(n) when is_number(n) and n > 0, do: "text-emerald-600"
  def growth_classes(n) when is_number(n) and n < 0, do: "text-red-600"
  def growth_classes(_), do: "text-slate-500"

  @doc "Color de la prima de la cláusula sobre el valor (verde barato → rojo caro)."
  def premium_classes(pct) when is_number(pct) and pct <= 55, do: "font-bold text-emerald-600"
  def premium_classes(pct) when is_number(pct) and pct <= 110, do: "font-bold text-amber-600"
  def premium_classes(_), do: "font-bold text-red-600"

  @doc "Importe con signo para ganancias/pérdidas proyectadas."
  def signed_money(nil), do: "?"

  def signed_money(n) when is_integer(n) do
    sign = if(n >= 0, do: "+", else: "−")
    sign <> money(abs(n))
  end

  def signed_money(n) when is_float(n), do: signed_money(trunc(n))
  def signed_money(other), do: to_string(other)

  def red_alert?(alert), do: String.contains?(alert, "PRESUPUESTO EN ROJO")

  @doc "Foto oficial del jugador por id (nil-safe para datos parciales)."
  def player_photo_url(nil), do: nil
  def player_photo_url(player_id), do: Mister.Client.player_photo_url(player_id)

  # Fusiona las ventas recomendadas del informe con las ofertas recibidas en
  # vivo (por player_id). Las ofertas sin venta asociada van al final.
  def sales_with_offers(nil, _offers), do: []

  def sales_with_offers(report, offers) do
    sells = List.wrap(report.sell_recommendations)

    matched_ids = Enum.map(sells, & &1["player_id"])

    sales =
      Enum.map(sells, fn rec ->
        %{rec: rec, offer: Enum.find(offers, &(&1.player_id == rec["player_id"]))}
      end)

    extras =
      offers
      |> Enum.reject(&(&1.player_id in matched_ids))
      |> Enum.map(fn offer -> %{rec: phantom_rec(offer), offer: offer} end)

    sales ++ extras
  end

  # Oferta sobre un jugador que ya no figura en el informe (report obsoleto):
  # mostramos los datos de la propia oferta.
  defp phantom_rec(offer) do
    %{
      "player_id" => offer.player_id,
      "name" => offer.name,
      "position" => offer.position,
      "trend" => to_string(offer.trend_dir),
      "market_price" => offer.value,
      "sale_range" => nil
    }
  end

  # Consejo de una oferta recibida. Si el jugador es titular en el mejor once,
  # la respuesta es siempre no vender: cruzamos venta con alineación.
  def sale_advice(%{"in_best_lineup" => true}, _offer),
    do: {:deny, "es titular en tu mejor once: retíralo de la venta, no lo vendas"}

  def sale_advice(_rec, nil), do: nil
  def sale_advice(_rec, offer), do: offer_advice(offer)

  def offer_advice_pct(%{bid: bid, value: value}) when is_integer(value) and value > 0,
    do: "#{trunc(bid / value * 100)}%"

  def offer_advice_pct(_), do: "?"

  # Línea de resultado económico de la operación: lo que pagamos vs la puja.
  def purchase_line(%{paid_price: paid, bid: bid}, _) when is_integer(paid) and is_integer(bid) do
    diff = bid - paid
    sign = if(diff >= 0, do: "+", else: "−")
    "lo compraste por #{money(paid)} · resultado de la venta: #{sign}#{money(abs(diff))}"
  end

  def purchase_line(_, _), do: nil

  # Recomendación de oferta recibida. Tres factores:
  #   * ganancia vs valor de mercado (bid/value)
  #   * expectativa: en alza, aguantar puede darnos más
  #   * beneficio real: lo pagamos vs lo que nos ofrecen (transfer.price)
  def offer_advice(%{bid: bid, value: value} = offer)
      when is_integer(bid) and is_integer(value) and value > 0 do
    ratio = bid / value
    gain = trunc((ratio - 1) * 100)
    profit_part = profit_part(offer)

    cond do
      # Plusvalía fuerte (≥50% sobre lo pagado) con una puja razonable:
      # mejor lo seguro aunque el jugador siga en alza.
      big_profit?(offer) and ratio >= 0.90 ->
        {:accept, "plusvalía fuerte#{profit_part}; mejor lo seguro"}

      offer[:trend_dir] == :up and ratio < 1.10 ->
        {:deny,
         "en alza: aguantando puedes ganar más (oferta al #{trunc(ratio * 100)}% del valor)#{profit_part}"}

      offer[:trend_dir] == :up ->
        {:accept, "+#{gain}% sobre un jugador en alza#{profit_part}: plus excelente"}

      offer[:trend_dir] == :down and ratio >= 0.90 ->
        {:accept,
         "tendencia bajista: asegura la venta al #{trunc(ratio * 100)}% del valor#{profit_part}"}

      ratio >= 1.0 ->
        {:accept, "puja ≥ valor de mercado (+#{gain}%)#{profit_part}"}

      sale_at_loss?(offer) and offer[:trend_dir] != :down ->
        {:deny, "por debajo del valor y encima venderías a pérdidas#{profit_part}"}

      in_profit?(offer) and ratio >= 0.95 ->
        {:accept, "cerca del valor y vendes con beneficio#{profit_part}"}

      big_profit?(offer) ->
        {:accept, "beneficio sólido frente a lo pagado#{profit_part}; asegura la plusvalía"}

      true ->
        {:deny, "solo #{trunc(ratio * 100)}% del valor y sin margen claro#{profit_part}"}
    end
  end

  def offer_advice(_), do: {:deny, "datos incompletos"}

  defp sale_at_loss?(%{paid_price: paid, bid: bid}) when is_integer(paid), do: bid < paid
  defp sale_at_loss?(_), do: false

  defp in_profit?(%{paid_price: paid, bid: bid}) when is_integer(paid), do: bid >= paid
  defp in_profit?(_), do: false

  # +50% o más sobre lo pagado: plusvalía difícil de rechazar aunque el
  # jugador siga valiendo algo más en el mercado.
  defp big_profit?(%{paid_price: paid, bid: bid}) when is_integer(paid) and paid > 0,
    do: (bid - paid) / paid >= 0.5

  defp big_profit?(_), do: false

  defp profit_part(%{paid_price: paid, bid: bid}) when is_integer(paid) and paid > 0 do
    pct = trunc((bid - paid) / paid * 100)
    sign = if(pct >= 0, do: "+", else: "")
    " · #{sign}#{pct}% sobre lo pagado"
  end

  defp profit_part(_), do: ""

  def offer_advice_classes({:accept, _}),
    do:
      "rounded-full bg-emerald-100 px-3 py-1 text-xs font-black uppercase text-emerald-800 ring-1 ring-emerald-300"

  def offer_advice_classes({:hold, _}),
    do:
      "rounded-full bg-amber-100 px-3 py-1 text-xs font-black uppercase text-amber-800 ring-1 ring-amber-300"

  def offer_advice_classes({:deny, _}),
    do:
      "rounded-full bg-red-100 px-3 py-1 text-xs font-black uppercase text-red-700 ring-1 ring-red-300"

  def offer_advice_label({:accept, _}), do: "Aceptar"
  def offer_advice_label({:hold, _}), do: "Valórala"
  def offer_advice_label({:deny, _}), do: "Rechazar"
end
