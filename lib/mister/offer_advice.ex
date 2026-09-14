defmodule Mister.OfferAdvice do
  @moduledoc """
  Consejo sobre una **oferta recibida** por un jugador en venta.

  Decide si conviene aceptarla o rechazarla a partir de tres factores:

    * la puja frente al valor de mercado (`bid / value`)
    * la expectativa: en alza puede compensar aguantar
    * el beneficio real: lo que lo compramos (`paid_price`) frente a la puja

  Un **titular** del mejor once nunca se vende: ese cruce viene en `context`.

  Módulo puro (sin HTTP ni base de datos). `offer` es el mapa normalizado de
  `Mister.Client` con `:paid_price` añadido por el adaptador; `context` solo
  lleva `:in_best_lineup`.
  """

  @doc """
  Devuelve `{:accept | :deny, motivo}`.

  `offer` necesita `:bid`, `:value`, `:trend_dir` y, para el beneficio,
  `:paid_price`. `context` es `%{in_best_lineup: boolean}`.
  """
  def advise(offer, context \\ %{}) do
    if context[:in_best_lineup] == true do
      {:deny, "es titular en tu mejor once: retíralo de la venta, no lo vendas"}
    else
      offer_advice(offer)
    end
  end

  @doc """
  Beneficio de la operación frente a lo pagado: `%{amount, pct}` o `nil` si no
  conocemos el precio de compra.
  """
  def profit(%{paid_price: paid, bid: bid})
      when is_integer(paid) and paid > 0 and is_integer(bid) do
    %{amount: bid - paid, pct: trunc((bid - paid) / paid * 100)}
  end

  def profit(_), do: nil

  ## Internals

  defp offer_advice(%{bid: bid, value: value} = offer)
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

  defp offer_advice(_), do: {:deny, "datos incompletos"}

  defp sale_at_loss?(%{paid_price: paid, bid: bid}) when is_integer(paid), do: bid < paid
  defp sale_at_loss?(_), do: false

  defp in_profit?(%{paid_price: paid, bid: bid}) when is_integer(paid), do: bid >= paid
  defp in_profit?(_), do: false

  # +50% o más sobre lo pagado: plusvalía difícil de rechazar aunque el
  # jugador siga valiendo algo más en el mercado.
  defp big_profit?(%{paid_price: paid, bid: bid}) when is_integer(paid) and paid > 0,
    do: (bid - paid) / paid >= 0.5

  defp big_profit?(_), do: false

  defp profit_part(offer) do
    case profit(offer) do
      %{pct: pct} when pct >= 0 -> " · +#{pct}% sobre lo pagado"
      %{pct: pct} -> " · #{pct}% sobre lo pagado"
      nil -> ""
    end
  end
end
