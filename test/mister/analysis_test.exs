defmodule Mister.AnalysisTest do
  use ExUnit.Case, async: true

  alias Mister.{Analysis, PlayerRow}

  defp build(input) do
    defaults = %{
      market_players: [],
      my_squad: [],
      squad_summary: %{},
      details_by_id: %{},
      balance: 0,
      rival_players: []
    }

    Analysis.build(Map.merge(defaults, input))
  end

  defp row(id, pos, opts \\ []) do
    %PlayerRow{
      player_id: id,
      name: Keyword.get(opts, :name, "P#{id}"),
      position: pos,
      price: Keyword.get(opts, :price, 1_000_000),
      season_avg: Keyword.get(opts, :avg, 5.0),
      trend: Keyword.get(opts, :trend, :flat),
      for_sale?: Keyword.get(opts, :for_sale?, false)
    }
  end

  # Detalle con la forma de `Mister.Client.player_detail/2` (sin el sobre data).
  defp detail(id, opts \\ []) do
    player =
      %{"id" => id, "avg" => Keyword.get(opts, :avg, 5.0)}
      |> maybe_put("value", Keyword.get(opts, :value))
      |> maybe_put("owner", Keyword.get(opts, :owner))
      |> maybe_put("clause", Keyword.get(opts, :clause))
      |> maybe_put("status", Keyword.get(opts, :status))
      |> maybe_put("injury", Keyword.get(opts, :injury))

    %{"player" => player, "values" => []}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  test "descarta los jugadores propios del mercado y de los clausulazos" do
    mine = row(1, 3, name: "Mío", trend: :up)
    free = row(2, 3, name: "Libre", trend: :up)

    report =
      build(%{
        market_players: [mine, free],
        my_squad: [mine],
        rival_players: [
          detail(1, owner: %{"id" => 9}, clause: %{"value" => 1_000_000}),
          detail(3, owner: %{"id" => 9}, clause: %{"value" => 1_000_000})
        ],
        balance: 10_000_000
      })

    assert Enum.map(report.buy_recommendations, & &1.player_id) == [2]
    assert Enum.map(report.clause_targets, & &1.player_id) == [3]
  end

  test "cruza mercado y rivales para los clausulazos" do
    market = row(10, 3, trend: :up)

    report =
      build(%{
        market_players: [market],
        details_by_id: %{10 => detail(10, owner: %{"id" => 7}, clause: %{"value" => 1_000_000})},
        rival_players: [detail(20, owner: %{"id" => 7}, clause: %{"value" => 1_000_000})],
        balance: 10_000_000
      })

    ids = report.clause_targets |> Enum.map(& &1.player_id) |> Enum.sort()
    assert ids == [10, 20]
  end

  test "solo los candidatos interesantes entran en los fichajes, con su valoración" do
    up = row(1, 4, trend: :up, avg: 1.0)
    bargain = row(2, 4, trend: :flat, avg: 2.0)
    meh = row(3, 4, trend: :flat, avg: 1.0)

    report = build(%{market_players: [up, bargain, meh], balance: 10_000_000})

    ids = report.buy_recommendations |> Enum.map(& &1.player_id) |> Enum.sort()
    assert ids == [1, 2]
    assert Enum.all?(report.buy_recommendations, &Map.has_key?(&1, :potential_gain))
  end

  test "el presupuesto usa el saldo real y suma las ventas proyectadas" do
    listed = row(1, 3, for_sale?: true, price: 3_000_000)

    report =
      build(%{
        my_squad: [listed],
        squad_summary: %{total_value: 50_000_000, balance: 1},
        balance: 2_000_000
      })

    assert report.budget_summary.real_now == 2_000_000
    assert report.budget_summary.real_projected == 5_000_000
    assert report.budget_summary.bid_rule == "balance_plus_25"
  end

  test "el once excluye lesionados y cruza las ventas con la alineación" do
    # 5 DEF (uno lesionado), 5 MID y 2 FWD: el once sale 3-5-2, así que sobra un
    # DEF. El MID 8 entra en el once y el DEF 6 se queda fuera.
    squad =
      [row(1, 1)] ++
        for(id <- 2..6, do: row(id, 2, for_sale?: id == 6)) ++
        for(id <- 7..11, do: row(id, 3, for_sale?: id == 8)) ++
        [row(12, 4), row(13, 4)]

    details = %{
      2 =>
        detail(2, status: "injury", injury: %{"description" => "lesión", "duration" => "2 sem"})
    }

    report = build(%{my_squad: squad, details_by_id: details, balance: 10_000_000})

    assert 2 in Enum.map(report.best_lineup.excluded, & &1.player_id)

    by_id = Map.new(report.sell_recommendations, &{&1.player_id, &1})
    assert by_id[8].verdict == "keep"
    assert by_id[6].verdict == "sell"
  end

  test "own_user_id sale del owner de un jugador propio" do
    squad = [row(1, 1)]
    details = %{1 => detail(1, owner: %{"id" => 14_655_780})}

    assert Analysis.own_user_id(squad, details) == 14_655_780
    assert Analysis.own_user_id(squad, %{}) == nil
  end
end
