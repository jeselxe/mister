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

  # Mínimo de puntos por millón de cláusula para considerar el clausulazo.
  @min_value_per_million 1.0
  # Tope de clausulazos en el informe (el resto son ruido).
  @max_targets 12

  @doc """
  Filtra y puntúa oportunidades de clausulazo pagables con `real_balance`.

  Cada oportunidad incluye `value_per_million` (media de puntos por millón de
  cláusula) y un `score` simple (`avg * 10 - clause/1M`) pensado como punto de
  partida para calibrar con datos reales de temporada.

  Recorrer todas las plantillas rivales deja cientos de cláusulas pagables, así
  que se aplica un mínimo de calidad (`:min_value_per_million`, por defecto 1.0
  pts/M€) y se limita a las mejores `:max_targets` (12 por defecto).

  El orden es por **rentabilidad**: `value_per_million` (puntos por millón de
  cláusula) descendente, con el `score` como desempate.
  """
  def find_opportunities(player_details, real_balance, opts \\ []) do
    min_ratio = Keyword.get(opts, :min_value_per_million, @min_value_per_million)
    max_targets = Keyword.get(opts, :max_targets, @max_targets)

    player_details
    |> Enum.filter(&has_owner?/1)
    |> Enum.map(&score/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.player_id)
    |> Enum.filter(&(&1.clause_price <= real_balance))
    |> Enum.filter(&(&1.value_per_million >= min_ratio))
    |> Enum.sort_by(&{&1.value_per_million, &1.score}, :desc)
    |> Enum.take(max_targets)
    |> Enum.map(&Map.put(&1, :urgency, :high))
  end

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
