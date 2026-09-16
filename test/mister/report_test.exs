defmodule Mister.ReportTest do
  use ExUnit.Case, async: true

  alias Mister.{PlayerRow, Report}
  alias Mister.Report.Input

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
      Report.build(%Input{
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

  test "sugiere poner en venta a suplentes débiles o en caída" do
    squad = [
      %PlayerRow{player_id: 1, name: "Titular", position: 3, price: 5_000_000, season_avg: 5.0},
      %PlayerRow{player_id: 2, name: "Muerto", position: 3, price: 1_000_000, season_avg: 0.0},
      %PlayerRow{player_id: 3, name: "Cuaja", position: 3, price: 1_500_000, season_avg: 2.0},
      %PlayerRow{player_id: 4, name: "Sube", position: 3, price: 1_500_000, season_avg: 2.0},
      %PlayerRow{
        player_id: 5,
        name: "Ya listado",
        position: 3,
        price: 1_000_000,
        season_avg: 0.0,
        for_sale?: true
      }
    ]

    lineup = %{
      formation: "4-4-2",
      players: [%{player_id: 1, name: "Titular", is_captain: false}]
    }

    valuations = %{
      2 => %{growth_7d: -20.0, value: 1_000_000, total_points: 0},
      3 => %{growth_7d: -8.0, value: 1_500_000, total_points: 8},
      4 => %{growth_7d: 15.0, value: 1_500_000, total_points: 8},
      5 => %{growth_7d: -20.0, value: 1_000_000, total_points: 0}
    }

    report =
      Report.build(%Input{
        budget: @budget,
        my_squad: squad,
        lineup: lineup,
        squad_summary: %{},
        valuations: valuations
      })

    ids = Enum.map(report.sell_hints, & &1.player_id)

    assert 2 in ids
    assert 3 in ids
    refute 4 in ids
    refute 1 in ids
    refute 5 in ids

    hint = Enum.find(report.sell_hints, &(&1.player_id == 2))
    assert hint.sale_range.expected == 1_000_000
    assert hint.reason =~ "no puntúa"
    assert report.budget_summary.sale_slots == %{listed: 1, max: 5, free: 4}
  end

  test "no sugiere listar si ya tienes 5 jugadores en venta" do
    listed =
      for id <- 1..5 do
        %PlayerRow{
          player_id: id,
          name: "Listado #{id}",
          position: 3,
          price: 1_000_000,
          season_avg: 0.0,
          for_sale?: true
        }
      end

    candidate = %PlayerRow{
      player_id: 6,
      name: "Candidato",
      position: 3,
      price: 1_000_000,
      season_avg: 0.0
    }

    valuations =
      Map.new(1..6, fn id -> {id, %{growth_7d: -20.0, value: 1_000_000, total_points: 0}} end)

    report =
      Report.build(%Input{
        budget: @budget,
        my_squad: listed ++ [candidate],
        lineup: %{formation: nil, players: []},
        squad_summary: %{},
        valuations: valuations
      })

    assert report.sell_hints == []
    assert report.budget_summary.sale_slots == %{listed: 5, max: 5, free: 0}
  end

  test "un titular en venta libera hueco para listar a otro" do
    listed =
      for id <- 1..5 do
        %PlayerRow{
          player_id: id,
          name: "Listado #{id}",
          position: 3,
          price: 1_000_000,
          season_avg: 3.0,
          for_sale?: true
        }
      end

    candidate = %PlayerRow{
      player_id: 6,
      name: "Candidato",
      position: 3,
      price: 1_000_000,
      season_avg: 0.0
    }

    # El jugador 1 (listado) es titular en el mejor once: al retirarlo se
    # libera un hueco para el candidato.
    lineup = %{
      formation: "4-4-2",
      players: [%{player_id: 1, name: "Listado 1", is_captain: false}]
    }

    valuations =
      Map.new(1..6, fn id -> {id, %{growth_7d: -20.0, value: 1_000_000, total_points: 0}} end)

    report =
      Report.build(%Input{
        budget: @budget,
        my_squad: listed ++ [candidate],
        lineup: lineup,
        squad_summary: %{},
        valuations: valuations
      })

    assert report.budget_summary.sale_slots == %{listed: 5, max: 5, free: 1}
    assert Enum.map(report.sell_hints, & &1.player_id) == [6]
  end

  test "no puja si tras la puja la operación es marginal o pierde en el pesimista" do
    candidate = %PlayerRow{
      player_id: 9,
      name: "A. Guevara",
      position: 3,
      price: 174_000,
      season_avg: 1.0,
      trend: :down
    }

    valuations = %{
      9 => %{
        growth_1d: 1.0,
        growth_7d: 8.8,
        growth_30d: 20.0,
        total_points: 1,
        projected_value: 189_902,
        resale_range: %{pessimistic: 180_407, expected: 189_902, optimistic: 199_397}
      }
    }

    report =
      Report.build(%Input{
        budget: %{@budget | bid_allowed_now: 5_000_000},
        buy_candidates: [candidate],
        valuations: valuations
      })

    assert [rec] = report.buy_recommendations
    assert rec.recommendation == "watch"
    assert rec.suggested_bid == nil
  end

  test "recomienda pujar por ganancia absoluta aunque el % sea menor" do
    candidate = %PlayerRow{
      player_id: 12,
      name: "A. Bretones",
      position: 2,
      price: 3_340_000,
      season_avg: 1.8,
      trend: :up
    }

    valuations = %{
      12 => %{
        growth_1d: 0.5,
        growth_7d: 11.9,
        growth_30d: 100.0,
        total_points: 7,
        projected_value: 3_758_315,
        resale_range: %{pessimistic: 3_570_399, expected: 3_758_315, optimistic: 3_946_231}
      }
    }

    report =
      Report.build(%Input{
        budget: %{@budget | bid_allowed_now: 10_000_000},
        buy_candidates: [candidate],
        valuations: valuations
      })

    assert [rec] = report.buy_recommendations
    assert rec.recommendation == "bid"
    assert rec.suggested_bid == 3_507_000
    assert rec.cost == 3_507_000
    assert rec.potential_gain == 251_315
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
      Report.build(%Input{
        budget: @budget,
        buy_candidates: candidates,
        valuations: valuations
      })

    by_id = Map.new(report.buy_recommendations, &{&1.player_id, &1})

    assert by_id[1].recommendation == "bid"
    assert by_id[1].suggested_bid
    assert by_id[1].resale_range.optimistic == 1_260_000
    assert by_id[1].potential_gain == 200_000
    assert by_id[1].potential_gain_optimistic == 260_000
    assert by_id[1].potential_gain_pessimistic == 140_000
    assert by_id[2].recommendation == "watch"
    assert by_id[2].suggested_bid == nil
  end

  test "las pujas llevan el id del listado y el dueño para poder pujar" do
    candidate = %PlayerRow{
      player_id: 1,
      name: "Chollo",
      position: 4,
      price: 1_000_000,
      trend: :up
    }

    valuations = %{
      1 => %{
        growth_1d: 2.0,
        growth_7d: 20.0,
        growth_30d: 40.0,
        projected_value: 1_200_000,
        resale_range: %{pessimistic: 1_140_000, expected: 1_200_000, optimistic: 1_260_000}
      }
    }

    report =
      Report.build(%Input{
        budget: @budget,
        buy_candidates: [candidate],
        valuations: valuations,
        market_listings: %{1 => %{id_market: 999, offeree_id: 7}}
      })

    assert [rec] = report.buy_recommendations
    assert rec.id_market == 999
    assert rec.offeree_id == 7
  end

  describe "actions/1" do
    test "clausulazo con dueño y puja" do
      report = %{
        clause_targets: [
          %{player_id: 1, name: "Mbappé", clause_price: 20_000_000, owner_name: "Fran"}
        ],
        buy_recommendations: [
          %{player_id: 2, name: "Nico", recommendation: "bid", suggested_bid: 8_000_000}
        ],
        sell_recommendations: [],
        sell_hints: []
      }

      actions = Report.actions(report)
      clause = Enum.find(actions, &(&1.kind == "clause"))

      assert clause.mister_id == 1
      assert clause.player_name == "Mbappé"
      assert clause.description =~ "20.000.000 €"
      assert clause.description =~ "de Fran"
      assert Enum.find(actions, &(&1.kind == "buy")).suggested_amount == 8_000_000
    end

    test "unsell para un titular listado y sell para el resto" do
      report = %{
        clause_targets: [],
        buy_recommendations: [],
        sell_recommendations: [
          %{
            player_id: 1,
            name: "Koke",
            verdict: "keep",
            in_best_lineup: true,
            sale_range: %{expected: 8_600_000}
          },
          %{
            player_id: 2,
            name: "Isco",
            verdict: "sell",
            in_best_lineup: false,
            sale_range: %{expected: 10_700_000}
          }
        ],
        sell_hints: []
      }

      actions = Report.actions(report)

      assert Enum.any?(actions, &(&1.kind == "unsell" and &1.mister_id == 1))
      assert Enum.any?(actions, &(&1.kind == "sell" and &1.mister_id == 2))
    end

    test "list para una pista de venta" do
      report = %{
        clause_targets: [],
        buy_recommendations: [],
        sell_recommendations: [],
        sell_hints: [
          %{player_id: 9, name: "Serrano", reason: "no puntúa", sale_range: %{expected: 160_000}}
        ]
      }

      [list] = Enum.filter(Report.actions(report), &(&1.kind == "list"))

      assert list.mister_id == 9
      assert list.suggested_amount == 160_000
      assert list.description =~ "Serrano"
    end
  end
end
