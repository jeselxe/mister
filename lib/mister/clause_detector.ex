defmodule Mister.ClauseDetector do
  @moduledoc """
  Detector de clausulazos rentables.

  Un clausulazo es **compra inmediata** pagando la cláusula directamente:
  solo cuenta el **saldo real disponible** (nunca el bonus de +25%, que es
  exclusivo de pujas de mercado) y es "primero que llega, se lo lleva",
  así que las oportunidades se marcan con urgencia alta.

  Los datos de cláusula vienen en el HTML de `/market` y en el JSON de
  `/ajax/sw/players`; no hace falta explorar plantillas rivales completas.
  """

  @doc """
  Filtra y puntúa oportunidades de clausulazo pagables con `real_balance`.

  Cada oportunidad incluye `value_per_million` (media de puntos por millón de
  cláusula) y un `score` simple (`avg * 10 - clause/1M`) pensado como punto de
  partida para calibrar con datos reales de temporada.
  """
  def find_opportunities(player_details, real_balance) do
    player_details
    |> Enum.filter(&has_owner?/1)
    |> Enum.map(&score/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1.clause_price <= real_balance))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.map(&Map.put(&1, :urgency, :high))
  end

  defp has_owner?(detail) do
    case get_player(detail)["owner"] || detail["owner"] do
      %{"id" => id} when not is_nil(id) -> true
      %{id: id} when not is_nil(id) -> true
      _ -> false
    end
  end

  defp score(detail) do
    player = get_player(detail)
    clause = player["clause"] || detail["clause"]
    avg = player["avg"] || detail["avg"] || 0.0

    case clause_value(clause) do
      nil ->
        nil

      clause_price ->
        %{
          player_id: player["id"],
          name: player["name"],
          clause_price: clause_price,
          season_avg: avg,
          value_per_million: Float.round(avg / max(clause_price / 1_000_000, 0.1), 2),
          score: avg * 10 - clause_price / 1_000_000
        }
    end
  end

  defp clause_value(%{"value" => v}) when is_integer(v), do: v
  defp clause_value(v) when is_integer(v), do: v
  defp clause_value(_), do: nil

  defp get_player(%{"player" => player} = detail) when is_map(player),
    do: Map.merge(detail, player)

  defp get_player(detail), do: detail
end
