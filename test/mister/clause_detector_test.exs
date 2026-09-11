defmodule Mister.ClauseDetectorTest do
  use ExUnit.Case, async: true

  alias Mister.ClauseDetector

  @rival %{
    "player" => %{
      "id" => 1,
      "name" => "Rival",
      "avg" => 5.0,
      "points" => 55,
      "position" => 4,
      "value" => 4_000_000,
      "owner" => %{"id" => 99},
      "clause" => %{"value" => 5_000_000}
    }
  }

  @free_agent %{
    "player" => %{
      "id" => 3,
      "name" => "Libre",
      "avg" => 5.0,
      "clause" => %{"value" => 5_000_000}
    }
  }

  test "detecta clausulazos pagables de rivales" do
    assert [
             %{
               name: "Rival",
               clause_price: 5_000_000,
               total_points: 55,
               position: 4,
               player_value: 4_000_000,
               clause_premium_pct: 25,
               urgency: :high
             }
           ] = ClauseDetector.find_opportunities([@rival], 10_000_000)
  end

  test "excluye agentes libres (sin propietario)" do
    assert ClauseDetector.find_opportunities([@free_agent], 10_000_000) == []
  end

  test "excluye cláusulas por encima del saldo real" do
    assert ClauseDetector.find_opportunities([@rival], 1_000_000) == []
  end

  test "deduplica jugadores repetidos" do
    assert length(ClauseDetector.find_opportunities([@rival, @rival], 10_000_000)) == 1
  end

  test "descarta cláusulas con poco rendimiento (pts/M€)" do
    flojo = %{
      "player" => %{
        "id" => 4,
        "name" => "Flojo",
        "avg" => 2.0,
        "owner" => %{"id" => 5},
        "clause" => %{"value" => 10_000_000}
      }
    }

    assert ClauseDetector.find_opportunities([flojo], 20_000_000) == []
  end

  test "limita a las mejores oportunidades" do
    candidates =
      for id <- 1..20 do
        %{
          "player" => %{
            "id" => id,
            "name" => "Bueno #{id}",
            "avg" => 5.0,
            "owner" => %{"id" => 5},
            "clause" => %{"value" => 1_000_000}
          }
        }
      end

    assert length(ClauseDetector.find_opportunities(candidates, 20_000_000, max_targets: 3)) == 3
  end
end
