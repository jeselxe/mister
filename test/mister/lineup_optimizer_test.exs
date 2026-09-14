defmodule Mister.LineupOptimizerTest do
  use ExUnit.Case, async: true

  alias Mister.{LineupOptimizer, PlayerRow}

  describe "captain_multiplier/1" do
    test "escala por valor de mercado" do
      assert LineupOptimizer.captain_multiplier(160_000) == 3.0
      assert LineupOptimizer.captain_multiplier(4_999_999) == 3.0
      assert LineupOptimizer.captain_multiplier(5_000_000) == 2.0
      assert LineupOptimizer.captain_multiplier(9_999_999) == 2.0
      assert LineupOptimizer.captain_multiplier(10_000_000) == 1.5
      assert LineupOptimizer.captain_multiplier(25_000_000) == 1.5
    end

    test "sin valor conocido asume x2" do
      assert LineupOptimizer.captain_multiplier(nil) == 2.0
      assert LineupOptimizer.captain_multiplier(0) == 2.0
    end
  end

  test "elige capitán por bonus (puntos x multiplicador), no por puntos" do
    lineup = LineupOptimizer.best_lineup(squad(), [])

    assert lineup.formation == "4-4-2"
    # Barato: 1M -> x3, media 6 -> bonus 6*(3-1) = 12
    # Caro:  12M -> x1.5, media 7 -> bonus 7*(1.5-1) = 3.5
    assert lineup.captain_id == 20
    assert lineup.captain_multiplier == 3.0
    # base 41 + bonus 12
    assert lineup.total_points == 53.0
  end

  test "con dos jugadores iguales, el multiplicador decide el total" do
    # Mismo equipo pero el delantero barato vs caro con la misma media.
    base =
      [row(1, "GK", 1, 1_000_000, 4.0)] ++
        for(i <- 2..5, do: row(i, "D#{i}", 2, 2_000_000, 3.0)) ++
        for(i <- 6..9, do: row(i, "M#{i}", 3, 3_000_000, 3.0))

    cheap = base ++ [row(20, "A", 4, 1_000_000, 6.0), row(21, "B", 4, 1_000_000, 6.0)]
    lineup = LineupOptimizer.best_lineup(cheap, [])

    assert lineup.captain_multiplier == 3.0
    # base 40 (4 + 12 + 12 + 6 + 6) + 6*(3-1)
    assert lineup.total_points == 52.0
  end

  test "el multiplicador no basta: manda puntos x (mult - 1)" do
    # x3 con 0.9 -> 1.8  vs  x1.5 con 4.0 -> 2.0  => gana el caro
    assert captain_of(cheap: 0.9, expensive: 4.0) == 21

    # x3 con 1.1 -> 2.2  vs  x1.5 con 4.0 -> 2.0  => gana el barato
    assert captain_of(cheap: 1.1, expensive: 4.0) == 20
  end

  test "mezcla forma reciente (50%) con media de temporada (50%)" do
    squad =
      [row(1, "GK", 1, 1_000_000, 3.0)] ++
        for(i <- 2..5, do: row(i, "D#{i}", 2, 2_000_000, 3.0)) ++
        for(i <- 6..9, do: row(i, "M#{i}", 3, 3_000_000, 3.0)) ++
        [row(20, "Fwd", 4, 1_000_000, 3.0), row(21, "Fwd2", 4, 12_000_000, 3.0)]

    # Forma reciente 6.0, media de temporada 3.0 -> 0.5*6 + 0.5*3 = 4.5
    detail = %{
      "player" => %{"id" => 20, "avg" => 3.0, "value" => 1_000_000, "status" => nil},
      "points" => for(_ <- 1..5, do: %{"points" => %{"points" => 6.0}})
    }

    lineup = LineupOptimizer.best_lineup(squad, [detail])
    player = Enum.find(lineup.players, &(&1.player_id == 20))

    assert player.expected_points == 4.5
  end

  defp captain_of(cheap: cheap_avg, expensive: exp_avg) do
    low_squad(cheap_avg, exp_avg) |> LineupOptimizer.best_lineup([]) |> Map.get(:captain_id)
  end

  # Base de relleno con bonus bajo (x3, media 0.5 -> +1) para que el capitán
  # solo pueda salir de los dos delanteros.
  defp low_squad(cheap_avg, exp_avg) do
    [row(1, "GK", 1, 1_000_000, 0.5)] ++
      for(i <- 2..5, do: row(i, "D#{i}", 2, 2_000_000, 0.5)) ++
      for(i <- 6..9, do: row(i, "M#{i}", 3, 3_000_000, 0.5)) ++
      [row(20, "Cheap", 4, 1_000_000, cheap_avg), row(21, "Expensive", 4, 12_000_000, exp_avg)]
  end

  defp squad do
    [row(1, "GK", 1, 1_000_000, 4.0)] ++
      for(i <- 2..5, do: row(i, "D#{i}", 2, 2_000_000, 3.0)) ++
      for(i <- 6..9, do: row(i, "M#{i}", 3, 3_000_000, 3.0)) ++
      [row(20, "Cheap", 4, 1_000_000, 6.0), row(21, "Expensive", 4, 12_000_000, 7.0)]
  end

  defp row(id, name, pos, price, avg),
    do: %PlayerRow{player_id: id, name: name, position: pos, price: price, season_avg: avg}
end
