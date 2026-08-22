defmodule Mister.PlayerRowParser do
  @moduledoc """
  Parser de filas de jugador del HTML de `/team` (plantilla propia).

  El `<li>` de un jugador es prácticamente idéntico al de `/market`, así que la
  extracción por fila vive aquí y `Mister.MarketParser` la reutiliza.

  Señales extraídas (según clases/atributos detectados en el DOM de Mister):

    * id del jugador — atributo `data-player-id` o id tipo `player-12345`
    * tendencia — `.value-arrow.green` / `.value-arrow.red`
    * cláusula caliente — presencia de `.clauses-ranking-emoji`
    * titular — clase `in-lineup` del `<li>`
    * en venta — clase `on-sale` / badge de venta
    * propietario — atributo `data-user-id`

  NOTA: los selectores están escritos de forma defensiva (varias alternativas)
  y habrá que calibrarlos contra HTML real capturado.
  """

  alias Mister.{ParseHelpers, PlayerRow}

  @doc "Extrae todas las filas de jugador de un documento HTML."
  def parse_all(html) when is_binary(html) do
    html
    |> Floki.parse_document!()
    |> player_nodes()
    |> Enum.map(&parse_row/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse_all(_), do: []

  @doc """
  Resumen económico de la plantilla desde `/team`: saldo actual y valor total
  del equipo. Busca etiquetas "Saldo" y "Valor" en el texto de la página.
  """
  def parse_squad_summary(html) when is_binary(html) do
    doc = Floki.parse_document!(html)
    text = Floki.text(doc)

    %{
      balance: find_labeled_amount(text, ["Saldo", "Balance"]),
      total_value: find_labeled_amount(text, ["Valor del equipo", "Valor equipo", "Valor"])
    }
  end

  def parse_squad_summary(_), do: %{balance: nil, total_value: nil}

  ## Internals

  defp player_nodes(doc) do
    doc
    |> Floki.find("[data-player-id], li[id^='player-']")
    |> case do
      [] -> Floki.find(doc, "li.player, .player-item, .market-player")
      nodes -> nodes
    end
  end

  @doc false
  def parse_row(node) do
    with {:ok, player_id} <- fetch_player_id(node),
         {:ok, name} <- fetch_name(node) do
      %PlayerRow{
        player_id: player_id,
        name: String.trim(name),
        position: position(node),
        price: money(node, [".price", ".player-price", "[data-price]"]),
        clause_value: money(node, [".clause", ".clause-value", "[data-clause]"]),
        trend: trend(node),
        season_avg: decimal(node, [".average", ".season-average", "[data-avg]"]),
        matchday_points: decimal(node, [".points", ".matchday-points", "[data-points]"]),
        owner_id: owner_id(node),
        hot_clause?: Floki.find(node, ".clauses-ranking-emoji") != [],
        in_lineup?: has_class?(node, "in-lineup"),
        for_sale?: has_class?(node, "on-sale") or has_class?(node, "for-sale")
      }
    else
      _ -> nil
    end
  end

  defp fetch_player_id(node) do
    case Floki.attribute(node, "data-player-id") do
      [id | _] ->
        case Integer.parse(id) do
          {n, ""} -> {:ok, n}
          _ -> {:error, :bad_id}
        end

      [] ->
        case ParseHelpers.extract_id(Floki.attribute(node, "id")) do
          nil -> {:error, :no_id}
          id -> {:ok, id}
        end
    end
  end

  defp fetch_name(node) do
    node
    |> Floki.find(".player-name, .name, h3, h4, a[title]")
    |> case do
      [el | _] ->
        case el |> Floki.text() |> String.trim() do
          "" -> {:error, :no_name}
          name -> {:ok, name}
        end

      [] ->
        {:error, :no_name}
    end
  end

  defp position(node) do
    case Floki.attribute(node, "data-position") do
      [pos | _] -> ParseHelpers.parse_int(pos)
      _ -> nil
    end
  end

  defp trend(node) do
    cond do
      Floki.find(node, ".value-arrow.green") != [] -> :up
      Floki.find(node, ".value-arrow.red") != [] -> :down
      true -> :flat
    end
  end

  defp money(node, selectors) do
    selectors
    |> Enum.flat_map(&Floki.find(node, &1))
    |> Enum.map(&ParseHelpers.parse_money(Floki.text(&1)))
    |> Enum.find(& &1)
  end

  defp decimal(node, selectors) do
    selectors
    |> Enum.flat_map(&Floki.find(node, &1))
    |> Enum.map(&ParseHelpers.parse_decimal(Floki.text(&1)))
    |> Enum.find(& &1)
  end

  defp owner_id(node) do
    case Floki.attribute(node, "data-user-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  defp has_class?(node, class) do
    node
    |> Floki.attribute("class")
    |> List.first()
    |> to_string()
    |> String.split()
    |> MapSet.member?(class)
  end

  defp find_labeled_amount(text, labels) do
    labels
    |> Enum.find_value(fn label ->
      case Regex.run(~r/#{label}\D{0,40}?([\d.,]+)/iu, text) do
        [_, raw] -> ParseHelpers.parse_money(raw)
        _ -> nil
      end
    end)
  end
end
