defmodule Mister.ClauseDetector do
  @moduledoc """
  Detector de clausulazos rentables.

  Un clausulazo es **compra inmediata** pagando la cláusula directamente:
  solo cuenta el **saldo real disponible** (nunca el bonus de +25%, que es
  exclusivo de pujas de mercado) y es "primero que llega, se lo lleva",
  así que las oportunidades se marcan con urgencia alta.

  Los datos de cláusula solo se obtienen del JSON (`/ajax/sw/players` para un
  jugador suelto o `/ajax/sw/users` → `data.team_now` para una plantilla
  rival completa). Un clausulazo se puede pagar sobre **cualquier** jugador
  rival, esté o no en venta, así que el job recorre las plantillas de la liga
  (`Mister.Rivals`) además del mercado.
  """

  # Media de puntos mínima para que el clausulazo aporte al once.
  @min_avg 2.5
  # Tope de prima sobre el valor de mercado. El precio "justo" es +50% (la
  # cláusula suele ser 1.5x el valor); por encima de +150% pagas más de 2.5x
  # el valor y casi nunca compensa.
  @max_premium_pct 150
  # Tope de clausulazos en el informe (el resto son ruido).
  @max_targets 12

  @doc """
  Filtra y puntúa oportunidades de clausulazo pagables con `real_balance`.

  Cada oportunidad incluye `value_per_million` (media por millón de cláusula),
  `clause_premium_pct` (cuánto supera la cláusula al valor de mercado) y un
  `score` (`avg * 10 - clause/1M`), útiles para mostrar y calibrar.

  Criterio (en orden): con dueño y cláusula, `cláusula <= saldo real`, media
  >= `:min_avg` (2.5 por defecto), prima <= `:max_premium_pct` (150% por
  defecto), **ordenar por media ajustada por prima** (`media / (1 + prima/100)`,
  descendente, con `media` como desempate) y quedarse con las `:max_targets`
  mejores (12). El tope se aplica **después** de ordenar.

  Así no gana la cláusula más barata (suelo de 1M sobre jugadores de 160k),
  sino el que más puntúa sin pagar una barbaridad sobre su valor de reventa.
  """
  def find_opportunities(player_details, real_balance, opts \\ []) do
    min_avg = Keyword.get(opts, :min_avg, @min_avg)
    max_premium = Keyword.get(opts, :max_premium_pct, @max_premium_pct)
    max_targets = Keyword.get(opts, :max_targets, @max_targets)

    player_details
    |> Enum.filter(&has_owner?/1)
    |> Enum.map(&score/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.player_id)
    |> Enum.filter(&(&1.clause_price <= real_balance))
    |> Enum.filter(&(&1.season_avg >= min_avg))
    |> Enum.filter(&premium_within?(&1, max_premium))
    |> Enum.sort_by(fn target -> {blended(target), target.season_avg} end, :desc)
    |> Enum.take(max_targets)
    |> Enum.map(&Map.put(&1, :urgency, :high))
  end

  # Sin valor de mercado conocido no se puede juzgar la prima: no se descarta.
  defp premium_within?(_target, nil), do: true
  defp premium_within?(%{clause_premium_pct: nil}, _max), do: true
  defp premium_within?(%{clause_premium_pct: pct}, max), do: pct <= max

  # Media ajustada por prima: puntos de media por unidad de sobreprecio. Con
  # prima +50% divide por 1.5; sin prima (o cláusula por debajo del valor) no
  # divide.
  defp blended(%{clause_premium_pct: nil, season_avg: avg}), do: avg

  defp blended(%{clause_premium_pct: pct, season_avg: avg}),
    do: avg / (1 + max(pct, 0) / 100)

  defp has_owner?(detail) do
    case get_player(detail)["owner"] || detail["owner"] do
      %{"id" => id} when is_integer(id) and id > 0 -> true
      %{id: id} when is_integer(id) and id > 0 -> true
      _ -> false
    end
  end

  defp score(detail) do
    player = get_player(detail)
    owner = player["owner"] || player[:owner] || %{}
    clause = player["clause"] || detail["clause"]
    avg = player["avg"] || detail["avg"] || 0.0

    case clause_value(clause) do
      nil ->
        nil

      clause_price ->
        player_value = player["value"] || detail["value"]

        %{
          player_id: player["id"],
          name: player["name"],
          owner_id: owner["id"] || owner[:id],
          owner_name: owner["name"] || owner[:name],
          position: player["position"] || detail["position"],
          team_logo_url: get_in(player, ["team", "logoUrl"]) || player["teamLogoUrl"],
          clause_price: clause_price,
          player_value: player_value,
          clause_premium_pct: premium_pct(clause_price, player_value),
          season_avg: avg,
          total_points: player["points"],
          value_per_million: Float.round(avg / max(clause_price / 1_000_000, 0.1), 2),
          score: avg * 10 - clause_price / 1_000_000
        }
    end
  end

  # Cuánto más caro sale el clausulazo frente al valor de mercado del jugador
  # (lo normal es la cláusula = 1.5x el valor).
  defp premium_pct(_clause, nil), do: nil
  defp premium_pct(_clause, 0), do: nil

  defp premium_pct(clause, value) when is_integer(clause) and is_integer(value),
    do: round((clause - value) / value * 100)

  defp premium_pct(_clause, _value), do: nil

  defp clause_value(%{"value" => v}) when is_integer(v), do: v
  defp clause_value(v) when is_integer(v), do: v
  defp clause_value(_), do: nil

  defp get_player(%{"player" => player} = detail) when is_map(player),
    do: Map.merge(detail, player)

  defp get_player(detail), do: detail
end
