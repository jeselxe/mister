defmodule Mister.Format do
  @moduledoc """
  Formateo compartido entre el dominio y la presentación.

  `money/1` era el único duplicado real (informe y vista): mismo separador de
  miles con punto y sufijo €.
  """

  @doc ~S(Importe en euros con separador de miles: `1234567 -> "1.234.567 €"`.)
  def money(nil), do: "?"
  def money(n) when is_binary(n), do: n
  def money(n), do: number(n) <> " €"

  @doc ~S(Número con separador de miles, sin sufijo: `1234567 -> "1.234.567"`.)
  def number(nil), do: ""
  def number(n) when is_binary(n), do: n
  def number(n) when is_float(n), do: n |> trunc() |> number()

  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3, 3, [])
    |> Enum.join(".")
    |> String.reverse()
  end
end
