defmodule Mister.LineupOptimizer do
  @moduledoc """
  Optimizador de alineación con capitán y exclusión de bajas.

  * Formaciones soportadas: 3-4-3, 3-5-2, 4-3-3, 4-4-2, 4-5-1, 5-3-2, 5-4-1.
  * **Capitán:** no puntúa x2 fijo. El multiplicador depende del **valor de
    mercado** del jugador (`captain_multiplier/1`): x3 si vale menos de 5M,
    x2 entre 5M y 10M, x1.5 a partir de 10M. Se elige al que maximiza el
    bonus (`puntos × (multiplicador − 1)`), así que un jugador barato y en
    forma puede ser mejor capitán que uno caro con algo más de media.
  * **Exclusión por lesión/sanción:** el filtro usa **lista blanca**
    (`nil`, `""`, `"ok"` = disponible; cualquier otro valor = no disponible),
    más seguro ante estados nuevos no vistos todavía (solo se ha confirmado
    `"injury"` para lesionados).

  Limitación conocida: la disponibilidad solo se puede comprobar en jugadores
  con detalle cargado (`/ajax/sw/players`); sin detalle se asume disponible.
  """

  alias Mister.PlayerRow

  @formations [
    {3, 4, 3},
    {3, 5, 2},
    {4, 3, 3},
    {4, 4, 2},
    {4, 5, 1},
    {5, 3, 2},
    {5, 4, 1}
  ]

  @available_statuses [nil, "", "ok"]

  @doc """
  Multiplicador de capitán según el valor de mercado (en euros):

    * valor bajo (>0 y <5M)      -> x3
    * valor medio (>=5M y <10M)  -> x2
    * valor alto (>=10M)         -> x1.5

  Sin valor conocido se asume x2 (el supuesto conservador previo).
  """
  def captain_multiplier(value) when is_integer(value) and value > 0 and value < 5_000_000,
    do: 3.0

  def captain_multiplier(value)
      when is_integer(value) and value >= 5_000_000 and value < 10_000_000,
      do: 2.0

  def captain_multiplier(value) when is_integer(value) and value >= 10_000_000, do: 1.5
  def captain_multiplier(_), do: 2.0

  @spec best_lineup([PlayerRow.t()], [map()]) :: map()
  def best_lineup(squad, player_details) do
    details_by_id = Map.new(player_details, &{get_player_id(&1), &1})
    expected_points = build_expected_points_map(squad, details_by_id)
    values = build_value_map(squad, details_by_id)

    {available, unavailable} = Enum.split_with(squad, &available?(&1, details_by_id))

    by_position =
      available
      |> Enum.group_by(& &1.position)
      |> Enum.map(fn {pos, players} ->
        {pos, Enum.sort_by(players, &Map.get(expected_points, &1.player_id, 0), :desc)}
      end)
      |> Map.new()

    result =
      @formations
      |> Enum.map(&build_for_formation(&1, by_position, expected_points, values))
      |> Enum.filter(& &1)
      |> Enum.max_by(& &1.total_points, fn -> nil end)

    case result do
      nil ->
        %{
          formation: nil,
          players: [],
          captain_id: nil,
          captain_multiplier: nil,
          total_points: 0,
          excluded: []
        }

      result ->
        Map.put(result, :excluded, format_excluded(unavailable, details_by_id))
    end
  end

  defp build_for_formation({def_n, mid_n, fwd_n}, by_position, expected_points, values) do
    gk = Enum.take(Map.get(by_position, 1, []), 1)
    def_ = Enum.take(Map.get(by_position, 2, []), def_n)
    mid = Enum.take(Map.get(by_position, 3, []), mid_n)
    fwd = Enum.take(Map.get(by_position, 4, []), fwd_n)

    total_needed = 1 + def_n + mid_n + fwd_n
    picked = gk ++ def_ ++ mid ++ fwd

    if length(picked) == total_needed do
      picked_with_points =
        Enum.map(picked, fn p ->
          p
          |> Map.put(:expected_points, Map.get(expected_points, p.player_id, 0))
          |> Map.put(:captain_multiplier, captain_multiplier(Map.get(values, p.player_id)))
        end)

      # El capitán es quien más aporta con su bonus, no quien más puntúa.
      captain =
        Enum.max_by(
          picked_with_points,
          &(&1.expected_points * (&1.captain_multiplier - 1))
        )

      picked_with_captain =
        Enum.map(picked_with_points, &Map.put(&1, :is_captain, &1.player_id == captain.player_id))

      base_total = picked_with_points |> Enum.map(& &1.expected_points) |> Enum.sum()

      total_with_captain_bonus =
        base_total + captain.expected_points * (captain.captain_multiplier - 1)

      %{
        formation: "#{def_n}-#{mid_n}-#{fwd_n}",
        players: picked_with_captain,
        captain_id: captain.player_id,
        captain_multiplier: captain.captain_multiplier,
        total_points: Float.round(total_with_captain_bonus * 1.0, 2)
      }
    end
  end

  defp available?(player, details_by_id) do
    case Map.get(details_by_id, player.player_id) do
      nil -> true
      detail -> status(detail) in @available_statuses
    end
  end

  defp status(detail),
    do: get_in(detail, ["player", "status"]) || detail["status"]

  defp reason(detail) do
    injury = get_in(detail, ["player", "injury"]) || detail["injury"]

    case injury do
      %{"description" => desc, "duration" => dur} -> "#{desc} (#{dur})"
      _ -> status(detail) || "no disponible"
    end
  end

  defp format_excluded(unavailable, details_by_id) do
    Enum.map(unavailable, fn p ->
      detail = Map.get(details_by_id, p.player_id)
      %{player_id: p.player_id, name: p.name, reason: reason(detail)}
    end)
  end

  defp build_expected_points_map(squad, details_by_id) do
    Map.new(squad, fn p ->
      {p.player_id, expected_points_for(p, Map.get(details_by_id, p.player_id))}
    end)
  end

  defp build_value_map(squad, details_by_id) do
    Map.new(squad, fn p ->
      {p.player_id, value_for(p, Map.get(details_by_id, p.player_id))}
    end)
  end

  defp value_for(%PlayerRow{price: price}, nil), do: price

  defp value_for(%PlayerRow{price: price}, detail),
    do: get_in(detail, ["player", "value"]) || detail["value"] || price

  defp expected_points_for(%PlayerRow{season_avg: avg}, nil), do: avg || 0.0

  defp expected_points_for(_p, detail) do
    # El detalle trae en `points` la lista de jornadas (cada una con
    # `points.points`); `player.points` es un total escalar y no sirve aquí.
    recent =
      (detail["points"] || [])
      |> Enum.filter(&(get_in(&1, ["points", "points"]) != nil))
      |> Enum.take(-5)

    if recent == [] do
      get_in(detail, ["player", "avg"]) || 0.0
    else
      recent
      |> Enum.map(&get_in(&1, ["points", "points"]))
      |> Enum.sum()
      |> Kernel./(length(recent))
    end
  end

  defp get_player_id(%{"player" => %{"id" => id}}) when not is_nil(id), do: id
  defp get_player_id(%{"id" => id}), do: id
  defp get_player_id(_), do: nil
end
