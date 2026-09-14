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
      |> assign(:action_map, action_map(actions_of(report)))
      |> assign(:offers, [])
      |> assign(:offers_error, nil)
      |> assign(:confirming, nil)
      |> assign(:only_bank, true)

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
    actions = actions_of(report)

    {:noreply,
     socket
     |> put_flash(:info, "Nuevo informe disponible ✅")
     |> assign(:report, report)
     |> assign(:actions, actions)
     |> assign(:action_map, action_map(actions))}
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

  # Aceptar una oferta real en Mister. Es irreversible (la venta es final),
  # así que se pide una segunda pulsación de confirmación.
  @impl true
  def handle_event("accept_offer", %{"id_bid" => id_bid, "amount" => amount}, socket) do
    id_bid = String.to_integer(id_bid)

    if socket.assigns[:confirming] == id_bid do
      case Mister.Client.accept_offer(id_bid, String.to_integer(amount)) do
        {:ok, :accepted} ->
          socket =
            case Enum.find(socket.assigns.offers, &(&1.id_bid == id_bid)) do
              nil -> socket
              offer -> complete_sale_action(socket, offer.player_id)
            end

          {:noreply,
           socket
           |> put_flash(:info, "Oferta aceptada ✅")
           |> load_offers()}

        {:error, reason} ->
          Logger.error("ReportLive: no se pudo aceptar la oferta: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "No se pudo aceptar la oferta")}
      end
    else
      {:noreply, assign(socket, :confirming, id_bid)}
    end
  end

  # Cancela la confirmación pendiente sin tocar la oferta.
  @impl true
  def handle_event("cancel_accept", _params, socket) do
    {:noreply, assign(socket, :confirming, nil)}
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

  # Filtro de fichajes: por defecto solo banca (agentes libres), porque no se
  # suele pujar por jugadores listados por otros usuarios.
  @impl true
  def handle_event("market_filter", %{"scope" => scope}, socket) do
    {:noreply, assign(socket, :only_bank, scope == "bank")}
  end

  ## Helpers de plantilla

  @doc "Filtra las pujas por origen: solo banca (agentes libres) o todas."
  def filter_buys(buys, true), do: Enum.filter(buys, &(&1["source"] == "banca"))
  def filter_buys(buys, false), do: buys

  defp load_offers(socket) do
    case Mister.Client.fetch_offers_received() do
      {:ok, offers} ->
        socket
        |> assign(:offers, Enum.map(offers, &enrich_with_purchase_price/1))
        |> assign(:offers_error, nil)
        |> assign(:confirming, nil)

      {:error, reason} ->
        Logger.warning("ReportLive: no se pudieron cargar las ofertas: #{inspect(reason)}")

        socket
        |> assign(:offers, [])
        |> assign(:offers_error, reason)
        |> assign(:confirming, nil)
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

  # Índice {kind, mister_id} => acción, para pintar los controles dentro de la
  # fila de su sección (el checklist ya no existe como sección aparte).
  defp action_map(actions) do
    Map.new(actions, fn action -> {{action.kind, action.mister_id}, action} end)
  end

  # Marca como hecha la acción "sell" del jugador cuya oferta se acaba de
  # aceptar desde el informe: la venta ya está hecha en Mister.
  defp complete_sale_action(socket, mister_id) do
    map = socket.assigns.action_map

    case Map.get(map, {"sell", mister_id}) do
      nil -> socket
      action -> update_action_status(socket, action.id, "done")
    end
  end

  defp update_action_status(socket, id, status) do
    action = Repo.get!(Mister.ReportAction, id)
    action = action |> Mister.ReportAction.changeset(%{status: status}) |> Repo.update!()

    actions =
      Enum.map(socket.assigns.actions, fn a ->
        if a.id == action.id, do: %{a | status: action.status}, else: a
      end)

    socket
    |> assign(:actions, actions)
    |> assign(:action_map, action_map(actions))
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

  @doc "Tooltip de media de puntos (evita comillas anidadas en HEEx)."
  def avg_title(rec), do: "media " <> pts(rec["season_avg"]) <> " pts"

  @doc "Texto sin el emoji inicial (el icono ya marca el tipo o la severidad)."
  def plain_text(text), do: String.replace(text, ~r/^[^\p{L}\p{N}]+/u, "")

  def done_or_dismissed?(nil), do: false
  def done_or_dismissed?(action), do: action.status in ["done", "dismissed"]

  @doc "Acción de venta de una fila (kind sell o unsell según el veredicto)."
  def sale_action(action_map, rec) do
    kind = if rec["verdict"] == "keep", do: "unsell", else: "sell"
    Map.get(action_map, {kind, rec["player_id"]})
  end

  attr :action, :map, default: nil

  @doc "Controles de la tarea (hecha / descartar / deshacer) dentro de su propia fila."
  def action_controls(%{action: nil} = assigns), do: ~H""

  def action_controls(assigns) do
    ~H"""
    <div class="flex shrink-0 items-center gap-1">
      <%= cond do %>
        <% done?(@action) -> %>
          <span
            class="flex h-7 w-7 items-center justify-center rounded-full bg-emerald-100 text-emerald-700"
            title="Hecha"
          >
            <.icon name="hero-check" class="h-4 w-4" />
          </span>
        <% @action.status == "dismissed" -> %>
          <span
            class="flex h-7 w-7 items-center justify-center rounded-full bg-slate-100 text-slate-500"
            title="Descartada"
          >
            <.icon name="hero-x-mark" class="h-4 w-4" />
          </span>
        <% true -> %>
          <button
            type="button"
            phx-click="complete_action"
            phx-value-id={@action.id}
            id={"complete-action-#{@action.id}"}
            title="Marcar como hecha"
            class="flex h-7 w-7 items-center justify-center rounded-full text-emerald-600 transition hover:bg-emerald-100 active:scale-90 phx-click-loading:pointer-events-none phx-click-loading:opacity-60"
          >
            <.icon name="hero-check" class="h-4 w-4" />
          </button>
          <button
            type="button"
            phx-click="dismiss_action"
            phx-value-id={@action.id}
            id={"dismiss-action-#{@action.id}"}
            title="Descartar"
            class="flex h-7 w-7 items-center justify-center rounded-full text-slate-500 transition hover:bg-slate-100 hover:text-slate-600 active:scale-90 phx-click-loading:pointer-events-none phx-click-loading:opacity-60"
          >
            <.icon name="hero-x-mark" class="h-4 w-4" />
          </button>
      <% end %>
      <button
        :if={done?(@action) or @action.status == "dismissed"}
        type="button"
        phx-click="undo_action"
        phx-value-id={@action.id}
        id={"undo-action-#{@action.id}"}
        title="Deshacer"
        class="flex h-7 w-7 items-center justify-center rounded-full text-slate-500 transition hover:bg-slate-100 hover:text-slate-600 active:scale-90 phx-click-loading:pointer-events-none phx-click-loading:opacity-60"
      >
        <.icon name="hero-arrow-path" class="h-4 w-4" />
      </button>
    </div>
    """
  end

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

  @doc "¿Hay margen a precio de mercado como para enseñar el deslizador de puja?"
  def slider?(%{"expected_resale" => expected, "price" => price})
      when is_integer(expected) and is_integer(price),
      do: expected > price

  def slider?(_), do: false

  attr :id, :string, required: true
  attr :rec, :map, required: true

  @doc """
  Deslizador de puja: mueve el importe y ve la ganancia al momento
  (`expected_resale - puja`), calculada en el cliente sin ir al servidor.
  """
  def bid_slider(assigns) do
    rec = assigns.rec
    expected = rec["expected_resale"] || 0
    price = rec["price"] || 0
    value = rec["suggested_bid"] || price
    gain = expected - value
    pct = if value > 0, do: Float.round(gain / value * 100, 1), else: 0.0

    assigns =
      assign(assigns,
        expected: expected,
        price: price,
        value: value,
        step: max(div(max(expected - price, 0), 50), 5_000),
        gain: gain,
        pct: pct,
        gain_class: if(gain >= 0, do: "text-emerald-600", else: "text-red-600")
      )

    ~H"""
    <details :if={slider?(@rec)} class="group mt-1.5">
      <summary class="inline-flex cursor-pointer list-none items-center gap-1 text-[11px] font-semibold text-sky-600 transition hover:text-sky-700 [&::-webkit-details-marker]:hidden">
        <.icon name="hero-adjustments-horizontal" class="h-3.5 w-3.5" /> ajustar puja
        <.icon
          name="hero-chevron-down"
          class="h-3.5 w-3.5 transition-transform group-open:rotate-180"
        />
      </summary>
      <div
        id={@id}
        phx-hook=".BidSlider"
        phx-update="ignore"
        data-expected={@expected}
        class="mt-1.5 rounded-lg bg-slate-50 px-2.5 py-2 ring-1 ring-slate-200"
      >
        <input
          type="range"
          min={@price}
          max={@expected}
          step={@step}
          value={@value}
          class="w-full accent-sky-600"
          aria-label="Importe de la puja"
        />
        <div class="mt-1 flex items-center justify-between gap-2 text-[11px] text-slate-500">
          <span>
            pujas <span data-out="bid" class="font-bold text-slate-700">{money(@value)}</span>
          </span>
          <span>
            ganancia
            <span data-out="gain" class={["font-black", @gain_class]}>{signed_money(@gain)}</span>
            (<span data-out="pct">{signed_pct(@pct)}</span>)
          </span>
        </div>
        <p class="mt-0.5 text-[11px] text-slate-500">
          reventa esperada {money(resale_edge(@rec, "pessimistic"))}–{money(
            resale_edge(@rec, "optimistic")
          )}
        </p>
      </div>
    </details>
    """
  end

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

  def offer_advice_classes({:deny, _}),
    do:
      "rounded-full bg-red-100 px-3 py-1 text-xs font-black uppercase text-red-700 ring-1 ring-red-300"

  def offer_advice_label({:accept, _}), do: "Aceptar"
  def offer_advice_label({:deny, _}), do: "Rechazar"
end
