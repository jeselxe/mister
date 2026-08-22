defmodule Mister.StandingsParser do
  @moduledoc """
  Parser de la clasificación (`POST /standings`).

  De aquí sale el censo completo de la liga: id, slug, nombre, puntos y valor
  de equipo de cada participante. Sirve para consultar rivales concretos vía
  `/ajax/sw/users` si hace falta contexto adicional (v2).
  """

  alias Mister.ParseHelpers

  @type standing :: %{
          user_id: String.t(),
          slug: String.t() | nil,
          name: String.t(),
          points: number() | nil,
          squad_value: integer() | nil
        }

  @doc "Filas de la clasificación, en orden de posición."
  @spec parse(binary()) :: [standing()]
  def parse(html) when is_binary(html) do
    html
    |> Floki.parse_document!()
    |> rows()
    |> Enum.map(&parse_row/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse(_), do: []

  defp rows(doc) do
    doc
    |> Floki.find("[data-user-id], .standing-row, .classification li, table tr")
    |> Enum.filter(&(Floki.text(&1) != ""))
  end

  defp parse_row(node) do
    user_id = user_id(node)
    name = name(node)

    if user_id && name do
      %{
        user_id: user_id,
        slug: slug(node),
        name: name,
        points: points(node),
        squad_value: squad_value(node)
      }
    end
  end

  defp user_id(node) do
    case Floki.attribute(node, "data-user-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  defp name(node) do
    node
    |> Floki.find(".user-name, .team-name, .name, a[href*='user'], td:nth-child(2)")
    |> case do
      [el | _] -> el |> Floki.text() |> String.trim() |> non_empty()
      [] -> nil
    end
  end

  defp slug(node) do
    case Floki.attribute(node, "a", "href") do
      [href | _] ->
        case Regex.run(~r{/([^/?]+)$}, href) do
          [_, slug] -> slug
          _ -> nil
        end

      [] ->
        nil
    end
  end

  defp points(node) do
    node
    |> Floki.find(".points, .total-points, td:last-child")
    |> case do
      [el | _] -> ParseHelpers.parse_decimal(Floki.text(el))
      [] -> nil
    end
  end

  defp squad_value(node) do
    node
    |> Floki.find(".team-value, .value, [data-value]")
    |> case do
      [el | _] -> ParseHelpers.parse_money(Floki.text(el))
      [] -> nil
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(name), do: name
end
