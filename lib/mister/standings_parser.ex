defmodule Mister.StandingsParser do
  @moduledoc """
  Parser de la clasificación (`POST /standings`).

  De aquí sale el censo de la liga: id, slug, nombre, puntos y valor de cada
  participante. Se usa para explorar las plantillas rivales vía
  `/ajax/sw/users` (ver `Mister.Rivals`), que es donde están las cláusulas de
  todos los jugadores de la liga.
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
    |> Enum.uniq_by(& &1.user_id)
  end

  def parse(_), do: []

  # Marcado actual: cada participante es un `a.user` con
  # `href="users/<id>/<slug>"`. Se mantiene `[data-user-id]` como respaldo.
  defp rows(doc) do
    case Floki.find(doc, "a[href*='users/'], a[data-event='select_gameuser']") do
      [] -> Floki.find(doc, "[data-user-id]")
      nodes -> nodes
    end
  end

  defp parse_row(node) do
    with {:ok, user_id, slug} <- user_ref(node),
         name when is_binary(name) <- name(node) do
      %{
        user_id: user_id,
        slug: slug,
        name: name,
        points: points(node),
        squad_value: squad_value(node)
      }
    else
      _ -> nil
    end
  end

  defp user_ref(node) do
    case Floki.attribute(node, "href") do
      [href | _] ->
        case Regex.run(~r{users/(\d+)/([^/?#]+)}, href) do
          [_, id, slug] -> {:ok, id, slug}
          _ -> :error
        end

      [] ->
        case Floki.attribute(node, "data-user-id") do
          [id | _] -> {:ok, id, nil}
          [] -> :error
        end
    end
  end

  defp name(node) do
    node
    |> Floki.find(".info .name, .user-name, .team-name, .name, td:nth-child(2)")
    |> case do
      [el | _] -> el |> Floki.text() |> String.trim() |> non_empty()
      [] -> nil
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

  # `.played` viene como "18 jugadores · € 90.188.000": hay que quedarse con el
  # importe tras el "€" (parse_money a secas tomaría el "18").
  defp squad_value(node) do
    node
    |> Floki.find(".played, .team-value, .value, [data-value]")
    |> case do
      [el | _] ->
        case Regex.run(~r/€\s*([\d.,]+)/, Floki.text(el)) do
          [_, raw] -> ParseHelpers.parse_money(raw)
          _ -> ParseHelpers.parse_money(Floki.text(el))
        end

      [] ->
        nil
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(name), do: name
end
