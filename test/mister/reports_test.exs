defmodule Mister.ReportsTest do
  use ExUnit.Case, async: true

  alias Mister.{PlayerRow, Reports}

  @budget %{
    bid_rule: :balance_only,
    real_now: 1_000_000,
    real_projected: 1_000_000,
    bid_allowed_now: 1_000_000,
    bid_allowed_projected: 1_000_000
  }

  test "cruza ventas con el mejor once: un titular no se vende" do
    squad = [
      %PlayerRow{player_id: 1, name: "Titular", position: 3, price: 5_000_000, for_sale?: true},
      %PlayerRow{player_id: 2, name: "Suplente", position: 3, price: 5_000_000, for_sale?: true}
    ]

    lineup = %{
      formation: "4-4-2",
      players: [%{player_id: 1, name: "Titular", is_captain: false}]
    }

    report =
      Reports.build(%{
        budget: @budget,
        my_squad: squad,
        lineup: lineup,
        squad_summary: %{},
        valuations: %{}
      })

    by_id = Map.new(report.sell_recommendations, &{&1.player_id, &1})

    assert by_id[1].verdict == "keep"
    assert by_id[1].in_best_lineup
    assert by_id[2].verdict == "sell"
    refute by_id[2].in_best_lineup

    assert Enum.any?(report.alerts, &String.contains?(&1, "Titular"))
  end

  test "solo asigna importe de puja a los candidatos con recomendación bid" do
    candidates = [
      %PlayerRow{player_id: 1, name: "Chollo", position: 4, price: 1_000_000, trend: :up},
      %PlayerRow{player_id: 2, name: "Caro", position: 4, price: 50_000_000, trend: :up}
    ]

    valuations = %{
      1 => %{
        growth_7d: 20.0,
        growth_1d: 2.0,
        growth_30d: 40.0,
        projected_value: 1_200_000,
        resale_range: %{pessimistic: 1_140_000, expected: 1_200_000, optimistic: 1_260_000}
      },
      2 => %{
        growth_7d: 20.0,
        growth_1d: 2.0,
        growth_30d: 40.0,
        projected_value: 60_000_000,
        resale_range: %{pessimistic: 57_000_000, expected: 60_000_000, optimistic: 63_000_000}
      }
    }

    report =
      Reports.build(%{
        budget: @budget,
        buy_candidates: candidates,
        valuations: valuations,
        squad_summary: %{},
        my_squad: [],
        lineup: %{}
      })

    by_id = Map.new(report.buy_recommendations, &{&1.player_id, &1})

    assert by_id[1].recommendation == "bid"
    assert by_id[1].suggested_bid
    assert by_id[2].recommendation == "watch"
    assert by_id[2].suggested_bid == nil
  end
end
