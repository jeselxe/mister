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
        assign(socket, :offers, offers)
        |> assign(:offers_error, nil)

      {:error, reason} ->
        Logger.warning("ReportLive: no se pudieron cargar las ofertas: #{inspect(reason)}")

        assign(socket, :offers, [])
        |> assign(:offers_error, reason)
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

  def trend_icon("up"), do: "hero-arrow-trending-up"
  def trend_icon("down"), do: "hero-arrow-trending-down"
  def trend_icon(_), do: "hero-arrow-long-right"

  def kind_icon("clause"), do: "hero-bolt"
  def kind_icon("buy"), do: "hero-shopping-bag"
  def kind_icon("sell"), do: "hero-banknotes"
  def kind_icon("lineup_change"), do: "hero-arrows-right-left"
  def kind_icon(_), do: "hero-check-circle"

  def kind_label("clause"), do: "Clausulazo"
  def kind_label("buy"), do: "Fichaje"
  def kind_label("sell"), do: "Venta"
  def kind_label("lineup_change"), do: "Alineación"
  def kind_label(_), do: "Tarea"

  def red_alert?(alert), do: String.contains?(alert, "PRESUPUESTO EN ROJO")

  @doc "Foto oficial del jugador por id (nil-safe para datos parciales)."
  def player_photo_url(nil), do: nil
  def player_photo_url(player_id), do: Mister.Client.player_photo_url(player_id)

  # Recomendación de oferta recibida: aceptar si la puja cubre el valor de
  # mercado (no regalamos el fichaje); si está claramente por debajo, rechazar.
  def offer_advice(%{bid: bid, value: value})
      when is_integer(bid) and is_integer(value) and value > 0 do
    ratio = bid / value

    cond do
      ratio >= 1.0 -> {:accept, "puja ≥ valor de mercado"}
      ratio >= 0.9 -> {:hold, "justa: #{trunc(ratio * 100)}% del valor"}
      true -> {:deny, "solo #{trunc(ratio * 100)}% del valor"}
    end
  end

  def offer_advice(_), do: {:deny, "datos incompletos"}

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
