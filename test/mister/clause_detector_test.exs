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

  test "ordena por rentabilidad (puntos por millón), no por score" do
    # A: media 3, cláusula 2M  -> ratio 1.5 (score 28)
    # B: media 10, cláusula 10M -> ratio 1.0 (score 90)
    rentable = %{
      "player" => %{
        "id" => 1,
        "name" => "Rentable",
        "avg" => 3.0,
        "owner" => %{"id" => 9},
        "clause" => %{"value" => 2_000_000}
      }
    }

    caro = %{
      "player" => %{
        "id" => 2,
        "name" => "Caro",
        "avg" => 10.0,
        "owner" => %{"id" => 9},
        "clause" => %{"value" => 10_000_000}
      }
    }

    names =
      [caro, rentable]
      |> ClauseDetector.find_opportunities(20_000_000)
      |> Enum.map(& &1.name)

    assert names == ["Rentable", "Caro"]
  end

  test "el tope se aplica tras ordenar: devuelve las mejores por ratio" do
    # Misma cláusula (1M) y medias 1..20 -> ratio = media. Con tope 3 deben
    # salir las tres mejores, no tres cualesquiera.
    candidates =
      for avg <- 1..20 do
        %{
          "player" => %{
            "id" => avg,
            "name" => "J#{avg}",
            "avg" => avg * 1.0,
            "owner" => %{"id" => 5},
            "clause" => %{"value" => 1_000_000}
          }
        }
      end

    targets = ClauseDetector.find_opportunities(candidates, 20_000_000, max_targets: 3)

    assert Enum.map(targets, & &1.player_id) == [20, 19, 18]
  end
end
