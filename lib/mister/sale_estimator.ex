defmodule Mister.SaleEstimator do
  @moduledoc """
  Estimador de ventas.

  Al poner un jugador "en venta", la banca hace una oferta al día (normalmente
  de madrugada) a un precio **aleatorio entre el 95% y el 105%** del valor de
  mercado. No es venta inmediata a precio fijo: hay que tratarlo como rango.
  """

  @doc "Rango pesimista/esperado/optimista para un valor de mercado dado."
  def expected_range(market_price) when is_integer(market_price) and market_price >= 0 do
    %{
      pessimistic: round(market_price * 0.95),
      expected: market_price,
      optimistic: round(market_price * 1.05)
    }
  end
end
