defmodule Mister.Format do
  @moduledoc """
  Formateo compartido entre el dominio y la presentación.

  `money/1` era el único duplicado real (informe y vista): mismo separador de
  miles con punto y sufijo €.
  """

  @doc ~S(Importe en euros con separador de miles: `1234567 -> "1.234.567 €"`.)
  def money(nil), do: "?"
  def money(n) when is_integer(n), do: format_money(n)
  def money(n) when is_float(n), do: n |> trunc() |> format_money()
  def money(n) when is_binary(n), do: n

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
