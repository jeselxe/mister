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

  test "puja por ROI aunque el dinero absoluto sea pequeño si pasa el suelo" do
    v = %{resale_range: %{pessimistic: 1_150_000, expected: 1_150_000, optimistic: 1_250_000}}

    # +9.5% de ROI y 100k € de ganancia: cumple ambos suelos.
    assert Valuation.recommendation(v, 1_000_000, bid: 1_050_000) == :bid
  end

  test "puja por dinero absoluto aunque el % sea menor" do
    v = %{resale_range: %{pessimistic: 3_570_000, expected: 3_758_000, optimistic: 3_946_000}}

    # 7.2% (< 8%) pero 251k € sobre la puja: compensa por dinero.
    assert Valuation.recommendation(v, 3_340_000, bid: 3_507_000) == :bid
  end

  test "no persigue migajas aunque el porcentaje sea alto" do
    v = %{resale_range: %{pessimistic: 60_000, expected: 70_000, optimistic: 80_000}}

    # +33% pero solo 17.5k €: por debajo del suelo absoluto.
    assert Valuation.recommendation(v, 50_000, bid: 52_500) == :watch
  end

  test "el atajo por pts/M€ exige una media mínima" do
    v = %{resale_range: %{pessimistic: 1_090_000, expected: 1_150_000, optimistic: 1_200_000}}

    assert Valuation.recommendation(v, 1_100_000,
             bid: 1_100_000,
             pts_per_million: 6.0,
             avg: 1.0
           ) == :watch

    assert Valuation.recommendation(v, 1_100_000,
             bid: 1_100_000,
             pts_per_million: 6.0,
             avg: 3.0
           ) == :bid
  end
end
