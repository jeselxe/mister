defmodule Mister.BudgetEngine do
  @moduledoc """
  Motor de presupuesto.

  Distingue dos bolsas que **no** se pueden mezclar:

    * **Clausulazos** — solo saldo real (actual o proyectado tras ventas).
      El bonus nunca aplica porque no es una puja de mercado.
    * **Pujas de mercado** — saldo + bonus según la regla configurada de la
      liga (`:balance_plus_25` por defecto; soporta `:balance_only`,
      `:balance_plus_50` y `:unlimited`).
  """

  @doc """
  Calcula el presupuesto disponible.

  `sale_candidates` son jugadores en venta con `expected_sale_price`
  (ver `Mister.SaleEstimator`).
  """
  def available_budget(current_balance, team_value, sale_candidates, bid_rule \\ nil) do
    bid_rule = bid_rule || Application.fetch_env!(:mister, :bid_rule)
    projected_from_sales = sale_candidates |> Enum.map(& &1.expected_sale_price) |> Enum.sum()

    %{
      bid_rule: bid_rule,
      # para CLAUSULAZOS: solo esto, nunca el bonus de +25%
      real_now: current_balance,
      real_projected: current_balance + projected_from_sales,
      # para PUJAS de mercado: aquí sí aplica el bonus de la liga
      bid_allowed_now: max_bid_allowed(current_balance, team_value, bid_rule),
      bid_allowed_projected:
        max_bid_allowed(current_balance + projected_from_sales, team_value, bid_rule)
    }
  end

  defp max_bid_allowed(_balance, _team_value, :unlimited), do: :unlimited

  defp max_bid_allowed(balance, team_value, :balance_plus_25),
    do: floor(balance + team_value * 0.25)

  defp max_bid_allowed(balance, team_value, :balance_plus_50),
    do: floor(balance + team_value * 0.5)

  defp max_bid_allowed(balance, _team_value, :balance_only), do: max(balance, 0)
end
