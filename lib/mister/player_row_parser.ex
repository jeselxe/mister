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
      total_value:
        case Floki.find(doc, ".squad-info .subtitle") do
          [el | _] ->
            # "€ 73.923.000 · 545.000 ↑" — el primer monto es el valor total
            el |> Floki.text() |> ParseHelpers.parse_money()

          [] ->
            find_labeled_amount(text, ["Valor del equipo", "Valor equipo"])
        end
    }
  end

  def parse_squad_summary(_), do: %{balance: nil, total_value: nil}

  ## Internals

  defp player_nodes(doc) do
    doc
    |> Floki.find("[data-player-id], li[data-position], li[id^='player-']")
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
        name: name |> String.trim() |> String.replace(~r/\s+/, " "),
        position: position(node),
        team_logo_url: team_logo_url(node),
        price:
          money(node, [".price", ".player-price"]) ||
            attr_money(node, "data-price") ||
            money(node, [".underName"]),
        clause_value: money(node, [".clause", ".clause-value"]),
        trend: trend(node),
        season_avg: decimal(node, [".avg", ".average", ".season-average"]),
        matchday_points: decimal(node, [".points", ".matchday-points"]),
        owner_id: owner_id(node),
        seller_name: seller_name(node),
        hot_clause?: Floki.find(node, ".clauses-ranking-emoji") != [],
        in_lineup?: has_class?(node, "in-lineup"),
        for_sale?: for_sale?(node)
      }
    else
      _ -> nil
    end
  end

  defp fetch_player_id(node) do
    case Floki.attribute(node, "data-player-id") do
      [id | _] ->
        integer_or_error(id)

      [] ->
        # Filas de mercado (`li[data-position]`): el id va en atributos
        # `data-id_player` de los elementos internos.
        case Floki.attribute(node, "[data-id_player]", "data-id_player") do
          [id | _] ->
            integer_or_error(id)

          [] ->
            case ParseHelpers.extract_id(Floki.attribute(node, "id")) do
              nil -> {:error, :no_id}
              id -> {:ok, id}
            end
        end
    end
  end

  defp integer_or_error(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_id}
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

  # Escudo del club del jugador. En la fila hay dos `.team-logo`: el del club
  # (dentro de `.icons`) y el del próximo rival (`.rival`), así que se prefiere
  # el primero.
  defp team_logo_url(node) do
    nodes =
      case Floki.find(node, ".icons .team-logo") do
        [] -> Floki.find(node, ".team-logo")
        found -> found
      end

    case nodes do
      [el | _] -> List.first(Floki.attribute(el, "src"))
      [] -> nil
    end
  end

  defp position(node) do
    # /team: el li no lleva data-position; está en el div interno
    # `.player-position[data-position]`. /market: en el propio li.
    with [] <- Floki.attribute(node, "data-position"),
         [] <- Floki.attribute(node, ".player-position", "data-position") do
      nil
    else
      [pos | _] -> ParseHelpers.parse_int(pos)
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
    case Floki.attribute(node, "data-user-id") ++ Floki.attribute(node, "data-owner") do
      [id | _] -> id
      [] -> nil
    end
  end

  defp attr_money(node, attr) do
    case Floki.attribute(node, attr) do
      [value | _] -> ParseHelpers.parse_money(value)
      [] -> nil
    end
  end

  # Nombre del vendedor en la cabecera de la fila de mercado:
  # "ElHu$tler," / "Aitor Sagasta," / "Libre," (banca) / "Jesus," (nosotros).
  defp seller_name(node) do
    case Floki.find(node, ".header .date") do
      [el | _] ->
        el
        |> Floki.text()
        |> String.split(",")
        |> List.first()
        |> String.trim()
        |> case do
          "" -> nil
          name -> name
        end

      [] ->
        nil
    end
  end

  # Un jugador está "en venta" cuando su botón de gestión es el variante
  # activa (clase btn--accent / texto "En venta"); si no, muestra "Gestionar".
  defp for_sale?(node) do
    node
    |> Floki.find(".btn-sale")
    |> Enum.any?(fn btn ->
      String.contains?(String.downcase(Floki.text(btn)), "en venta") or
        has_class?(btn, "btn--accent")
    end)
  end

  defp has_class?(node, class) do
    node
    |> Floki.attribute("class")
    |> List.first()
    |> to_string()
    |> String.split()
    |> Enum.member?(class)
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
