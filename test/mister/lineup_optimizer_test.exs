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

  defp squad do
    [row(1, "GK", 1, 1_000_000, 4.0)] ++
      for(i <- 2..5, do: row(i, "D#{i}", 2, 2_000_000, 3.0)) ++
      for(i <- 6..9, do: row(i, "M#{i}", 3, 3_000_000, 3.0)) ++
      [row(20, "Cheap", 4, 1_000_000, 6.0), row(21, "Expensive", 4, 12_000_000, 7.0)]
  end

  defp row(id, name, pos, price, avg),
    do: %PlayerRow{player_id: id, name: name, position: pos, price: price, season_avg: avg}
end
