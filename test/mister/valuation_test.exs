defmodule Mister.ValuationTest do
  use ExUnit.Case, async: true

  alias Mister.Valuation

  @rising %{
    "player" => %{"value" => 1_000_000, "points" => 42},
    "values" => [
      %{"time" => "Un día", "change" => 10_000, "value" => 990_000},
      %{"time" => "Una semana", "change" => 100_000, "value" => 900_000},
      %{"time" => "Un mes", "change" => 500_000, "value" => 500_000}
    ]
  }

  test "calcula crecimiento día/semana/mes y proyecta el valor" do
    v = Valuation.from_detail(@rising)

    assert v.value == 1_000_000
    assert v.total_points == 42
    assert v.growth_1d == 1.0
    assert v.growth_7d == 11.1
    assert v.growth_30d == 100.0
    assert v.projected_value > v.value
    assert v.resale_range.expected == v.projected_value
    assert v.resale_range.pessimistic == round(v.projected_value * 0.95)
  end

  test "recomienda pujar cuando la revalorización supera el umbral" do
    v = Valuation.from_detail(@rising)

    assert Valuation.recommendation(v, 1_000_000) == :bid
  end

  test "no recomienda pujar si no es asequible" do
    v = Valuation.from_detail(@rising)

    assert Valuation.recommendation(v, 1_000_000, affordable?: false) == :watch
  end

  test "solo sigue a un jugador en caída aunque tenga buen ratio puntos/precio" do
    falling = %{
      "player" => %{"value" => 1_000_000},
      "values" => [%{"time" => "Una semana", "change" => -200_000, "value" => 1_200_000}]
    }

    v = Valuation.from_detail(falling)

    assert v.growth_7d == -16.7
    assert v.projected_value < v.value
    assert Valuation.recommendation(v, 1_000_000, pts_per_million: 3.0) == :watch
  end

  test "usa el valor de respaldo cuando no hay detalle" do
    v = Valuation.from_detail(%{}, 500_000)

    assert v.value == 500_000
    assert v.projected_value == 500_000
    assert v.growth_7d == nil
  end
end
