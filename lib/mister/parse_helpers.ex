defmodule Mister.ParseHelpers do
  @moduledoc """
  Utilidades compartidas por los parsers HTML (Floki).

  Mister formatea el dinero con puntos como separador de miles
  (p. ej. `"12.500.000 €"`), a veces con decimales con coma.
  """

  @doc """
  Convierte texto de dinero de Mister a entero. Devuelve `nil` si no hay número.

      iex> Mister.ParseHelpers.parse_money("12.500.000 €")
      12500000

      iex> Mister.ParseHelpers.parse_money("1.5")
      nil
  """
  def parse_money(text) when is_binary(text) do
    case Regex.run(~r/\d[\d.,]*\d|\d/, text) do
      [raw] ->
        digits = String.replace(raw, [".", ","], "")

        case Integer.parse(digits) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def parse_money(_), do: nil

  @doc "Convierte texto decimal de Mister (`\"7,25\"`, `\"7.25\"`) a float."
  def parse_decimal(text) when is_binary(text) do
    case Regex.run(~r/\d+[.,]?\d*/, String.replace(text, "\u00a0", " ")) do
      [raw] ->
        {f, _} = Float.parse(String.replace(raw, ",", "."))
        f

      _ ->
        nil
    end
  end

  def parse_decimal(_), do: nil

  @doc "Extrae un entero plano de texto (puntos, ids...)."
  def parse_int(text) when is_binary(text) do
    case Regex.run(~r/-?\d+/, text) do
      [raw] -> String.to_integer(raw)
      _ -> nil
    end
  end

  def parse_int(_), do: nil

  @doc "Primer id numérico dentro de un atributo tipo `player-12345`."
  def extract_id(nil), do: nil

  def extract_id(value) when is_list(value),
    do: value |> List.first() |> extract_id()

  def extract_id(value) when is_binary(value) do
    case Regex.run(~r/(\d{3,})/, value) do
      [_, id] -> String.to_integer(id)
      _ -> nil
    end
  end

  def extract_id(_), do: nil
end
