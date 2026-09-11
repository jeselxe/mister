defmodule Mister.Valuation do
  @moduledoc """
  Valoración de un jugador a partir del detalle de `/ajax/sw/players`.

  Mister ya devuelve el histórico de valor (`data.values` con la variación a
  un día / una semana / un mes). De ahí sacamos:

    * **crecimiento** reciente (día / semana / mes) en porcentaje
    * **proyección** de valor a un horizonte corto (7 días por defecto)
    * **rango de reventa**: la banca puja entre el 95% y el 105% del valor
      (ver `Mister.SaleEstimator`)

  Con esto el informe puede separar "pujar ahora" de "solo seguir": no todo
  jugador en alza merece una puja, solo el que tiene recorrido suficiente
  (o un ratio puntos/precio excelente) para compensar el riesgo.

  Las proyecciones son una extrapolación simple del crecimiento reciente,
  con tope de ±5%/día para no amplificar burbujas puntuales. Los umbrales
  son parámetros de calibración, no verdad absoluta.
  """

  @horizon_days 7
  @max_daily_rate 0.05
  @min_daily_rate -0.05
  # ROI objetivo (revalorización proyectada / coste de la puja).
  @bid_gain_pct 8.0
  # O una ganancia absoluta relevante aunque el % sea menor: 250k € en una
  # semana es dinero real aunque sobre un jugador caro sea "solo" un 5%.
  @bid_gain_abs 250_000
  # Suelos para no perseguir migajas (ni % alto sin dinero) ni inmovilizar
  # capital por calderilla.
  @bid_min_gain_pct 3.0
  @bid_min_gain_abs 50_000
  # O un ratio puntos por millón que compense aunque la proyección no destaque.
  @bid_pts_per_million 2.0
  # Y, en ese atajo, el jugador debe ser al menos titularizable (si no, su
  # ratio alto solo refleja que es barato/inservible).
  @bid_min_avg 2.5

  @doc """
  Calcula crecimiento, proyección y rango de reventa a partir de un detalle.

  `fallback_value` se usa si el detalle no trae `player.value` (p. ej. una
  fila de mercado sin detalle cargado).
  """
  def from_detail(detail, fallback_value \\ nil) do
    detail = detail || %{}
    player = detail["player"] || %{}
    value = player["value"] || fallback_value
    values = detail["values"] || []

    day = growth(values, "día")
    week = growth(values, "semana")
    month = growth(values, "mes")

    projected = project(value, daily_rate(day, week))

    %{
      value: value,
      total_points: player["points"],
      growth_1d: day,
      growth_7d: week,
      growth_30d: month,
      horizon_days: @horizon_days,
      projected_value: projected,
      resale_range: resale_range(projected)
    }
  end

  @doc "Rango de reventa esperado (banca 95%–105% del valor proyectado)."
  def resale_range(nil), do: %{pessimistic: nil, expected: nil, optimistic: nil}

  def resale_range(value) when is_integer(value) do
    %{
      pessimistic: round(value * 0.95),
      expected: value,
      optimistic: round(value * 1.05)
    }
  end

  @doc """
  Decide si el jugador merece una puja (`:bid`) o solo seguimiento (`:watch`).

  `price` es el precio de salida y `opts` acepta:

    * `:bid` — lo que costaría de verdad la puja; la ganancia se mide contra
      este importe (no contra el precio de salida, que se queda corto).
    * `:affordable?` — si la puja cabe en el presupuesto.
    * `:pts_per_million` y `:avg` — atajo por valor (puntos por millón) para
      jugadores útiles.

  Además de superar el umbral, la operación debe ser atractiva **en porcentaje
  o en dinero**: un 5% sobre un jugador caro puede dejar más euros que un 40%
  sobre uno barato, así que vale cualquiera de las dos vías, con suelos para no
  perseguir migajas. La ganancia se mide siempre contra la puja (coste real).
  """
  def recommendation(valuation, price, opts \\ []) do
    affordable? = Keyword.get(opts, :affordable?, true)
    pts_per_million = Keyword.get(opts, :pts_per_million)
    avg = Keyword.get(opts, :avg)
    cost = Keyword.get(opts, :bid) || price
    expected = get_in(valuation, [:resale_range, :expected])
    gain = gain(expected, cost)
    pct = gain_pct(expected, cost)

    cond do
      not affordable? ->
        :watch

      attractive?(gain, pct) ->
        :bid

      is_number(pts_per_million) and pts_per_million >= @bid_pts_per_million and
        is_number(avg) and avg >= @bid_min_avg and is_number(gain) and
          gain >= @bid_min_gain_abs ->
        :bid

      true ->
        :watch
    end
  end

  # Atractiva por ROI (≥ 8%) o por dinero absoluto (≥ 250k), siempre que pase
  # los suelos (≥ 3% y ≥ 50k) para no recomendar migajas.
  defp attractive?(gain, pct) do
    is_number(gain) and gain >= @bid_min_gain_abs and
      is_number(pct) and pct >= @bid_min_gain_pct and
      (pct >= @bid_gain_pct or gain >= @bid_gain_abs)
  end

  @doc "Ganancia absoluta de revender a `resale` algo comprado a `price`."
  def gain(_resale, nil), do: nil
  def gain(nil, _price), do: nil
  def gain(resale, price), do: resale - price

  @doc "Ganancia porcentual de revender a `resale` algo comprado a `price`."
  def gain_pct(_resale, nil), do: nil
  def gain_pct(nil, _price), do: nil
  def gain_pct(_resale, 0), do: nil

  def gain_pct(resale, price) when is_integer(resale) and is_integer(price),
    do: Float.round((resale - price) / price * 100, 1)

  def gain_pct(_resale, _price), do: nil

  ## Internals

  # `values` viene como [%{"time" => "Un día", "change" => 31000, "value" => 5293000}, ...],
  # donde `value` es el valor pasado y `change` = valor actual - valor pasado.
  defp growth(values, needle) do
    case Enum.find(values, &time_matches?(&1["time"], needle)) do
      %{"change" => change, "value" => past}
      when is_integer(change) and is_integer(past) and past > 0 ->
        Float.round(change / past * 100, 1)

      _ ->
        nil
    end
  end

  defp time_matches?(time, needle) when is_binary(time),
    do: time |> String.downcase() |> String.contains?(needle)

  defp time_matches?(_, _), do: false

  # Ritmo diario para proyectar: preferimos la semana (más estable y
  # coherente con el crecimiento que mostramos); si no hay, el día.
  defp daily_rate(day, week) do
    cond do
      is_number(week) -> rate(week, 7)
      is_number(day) -> rate(day, 1)
      true -> 0.0
    end
    |> clamp()
  end

  defp rate(nil, _days), do: nil
  defp rate(pct, days), do: pct / 100 / days

  defp clamp(rate), do: rate |> max(@min_daily_rate) |> min(@max_daily_rate)

  defp project(nil, _daily), do: nil

  defp project(value, daily) when is_integer(value),
    do: round(value * :math.pow(1 + daily, @horizon_days))

  defp project(_value, _daily), do: nil
end
