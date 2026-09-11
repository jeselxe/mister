defmodule MisterWeb.ReportLiveTest do
  use MisterWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Mister.Repo
  alias Mister.ReportAction

  @endpoint MisterWeb.Endpoint

  describe "sin informe" do
    test "muestra el estado vacío con botón para lanzar el análisis", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#empty-report")
      assert has_element?(view, "#run-analysis")
    end

    test "encola el job de análisis al pulsar el botón", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert view |> element("#run-analysis") |> render_click() =~ "Análisis encolado"

      assert Repo.exists?(
               from j in Oban.Job,
                 where: j.worker == ^"Mister.Workers.DailyAnalysis",
                 where: j.state in ["available", "scheduled", "suspended"]
             )
    end
  end

  describe "con informe" do
    setup do
      report = build_report()
      %{report: report}
    end

    test "renderiza alertas, presupuesto, checklist y alineación", %{conn: conn, report: report} do
      {:ok, view, _html} = live(conn, "/")

      # alerta de presupuesto en rojo (prioridad máxima del spec)
      assert has_element?(view, "#alerts", "PRESUPUESTO EN ROJO")
      assert has_element?(view, "#budget-summary")
      assert render(view) =~ "-1.000 €"

      # clausulazos
      assert has_element?(view, "#clause-2001", "Kylian Mbappé")
      assert has_element?(view, "#clause-2001", "de ElHu$tler")
      assert has_element?(view, "#clause-2001", "21 pts")
      assert has_element?(view, "#clause-2001", "DC")
      assert has_element?(view, "#clause-2001", "valor 15.000.000 €")
      assert has_element?(view, "#clause-2001", "+33% sobre valor")
      assert has_element?(view, "#clauses")

      # alineación visual
      assert has_element?(view, "#formation-pitch")
      assert has_element?(view, "#best-lineup", "4-4-2")
      assert has_element?(view, "#excluded-players", "lesión de tobillo")

      # checklist
      [clause_action | rest] = Enum.sort_by(report.actions, & &1.id)
      assert has_element?(view, "#action-#{clause_action.id}", "Clausulazo: Kylian Mbappé")
      assert Enum.any?(rest, &has_element?(view, "#action-#{&1.id}"))
    end

    test "marca una tarea como hecha y persiste el estado", %{conn: conn, report: report} do
      action = List.first(report.actions)
      {:ok, view, _html} = live(conn, "/")

      assert view |> element("#complete-action-#{action.id}") |> render_click()

      assert Repo.reload!(action).status == "done"
      assert has_element?(view, "#undo-action-#{action.id}")
    end

    test "descarta una tarea y se puede deshacer", %{conn: conn, report: report} do
      action = List.first(report.actions)
      {:ok, view, _html} = live(conn, "/")

      view |> element("#dismiss-action-#{action.id}") |> render_click()
      assert Repo.reload!(action).status == "dismissed"

      view |> element("#undo-action-#{action.id}") |> render_click()
      assert Repo.reload!(action).status == "pending"
    end

    test "separa pujas de seguimientos y muestra la revalorización", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # puja recomendada con importe
      assert has_element?(view, "#buy-3001", "pujar hasta")
      assert has_element?(view, "#buy-3001", "12.5%")
      assert has_element?(view, "#buy-3001", "30 pts totales")

      # seguimiento sin puja
      assert has_element?(view, "#watch-3002", "sin puja")
    end

    test "un titular en venta se marca como no vender", %{conn: conn, report: report} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#sale-4002", "No vender")
      assert has_element?(view, "#sale-4002", "titular")
      assert has_element?(view, "#alerts", "titulares en tu mejor once")

      unsell = Enum.find(report.actions, &(&1.kind == "unsell"))
      assert unsell
      assert has_element?(view, "#action-#{unsell.id}", "Retirar de la venta")
    end

    test "se actualiza solo cuando llega un nuevo informe por PubSub", %{
      conn: conn,
      report: report
    } do
      {:ok, view, _html} = live(conn, "/")

      updated = %{report | alerts: ["Informe regenerado"]}

      Phoenix.PubSub.broadcast(Mister.PubSub, "reports", {:new_report, updated})

      assert render(view) =~ "Nuevo informe disponible"
      assert render(view) =~ "Informe regenerado"
    end
  end

  ## Fixtures

  defp build_report do
    report_map = %{
      report_date: Date.utc_today(),
      budget_summary: %{
        balance: -1_000,
        total_value: 50_000_000,
        real_now: -1_000,
        real_projected: 4_000,
        bid_allowed_now: 12_499_000,
        bid_allowed_projected: 12_504_000,
        bid_rule: "balance_plus_25"
      },
      buy_recommendations: [
        %{
          player_id: 3001,
          name: "Nico Williams",
          position: 4,
          price: 8_000_000,
          season_avg: 7.2,
          total_points: 30,
          pts_per_million: 0.9,
          trend: "up",
          growth_1d: 0.5,
          growth_7d: 12.5,
          growth_30d: 40.0,
          projected_value: 9_200_000,
          expected_resale: 9_200_000,
          potential_gain: 1_200_000,
          potential_gain_pct: 15.0,
          recommendation: "bid",
          source: "banca",
          seller_name: nil,
          suggested_bid: 8_400_000
        },
        %{
          player_id: 3002,
          name: "Aitor Ruibal",
          position: 2,
          price: 2_000_000,
          season_avg: 3.0,
          total_points: 12,
          pts_per_million: 1.5,
          trend: "up",
          growth_1d: 0.2,
          growth_7d: 1.0,
          growth_30d: 2.0,
          projected_value: 2_020_000,
          expected_resale: 2_020_000,
          potential_gain: 20_000,
          potential_gain_pct: 1.0,
          recommendation: "watch",
          source: "usuario",
          seller_name: "Fran",
          suggested_bid: nil
        }
      ],
      sell_recommendations: [
        %{
          player_id: 4001,
          name: "Iago Aspas",
          position: 4,
          trend: "down",
          growth_7d: -3.1,
          projected_value: 2_900_000,
          market_price: 3_000_000,
          in_best_lineup: false,
          verdict: "sell",
          sale_range: %{pessimistic: 2_850_000, expected: 3_000_000, optimistic: 3_150_000}
        },
        %{
          player_id: 4002,
          name: "Koke",
          position: 3,
          trend: "down",
          growth_7d: -3.3,
          projected_value: 8_300_000,
          market_price: 8_600_000,
          in_best_lineup: true,
          verdict: "keep",
          sale_range: %{pessimistic: 8_170_000, expected: 8_600_000, optimistic: 9_030_000}
        }
      ],
      clause_targets: [
        %{
          player_id: 2001,
          name: "Kylian Mbappé",
          owner_id: 14_660_410,
          owner_name: "ElHu$tler",
          position: 4,
          clause_price: 20_000_000,
          player_value: 15_000_000,
          clause_premium_pct: 33,
          season_avg: 8.5,
          total_points: 21,
          value_per_million: 0.9,
          score: 62.5,
          urgency: :high
        }
      ],
      best_lineup: %{
        formation: "4-4-2",
        players: [
          %{
            player_id: 101,
            name: "Unai Simón",
            position: 1,
            expected_points: 5.8,
            is_captain: false
          },
          %{
            player_id: 102,
            name: "Pedro Porro",
            position: 2,
            expected_points: 6.1,
            is_captain: false
          },
          %{
            player_id: 103,
            name: "Alejandro Balde",
            position: 2,
            expected_points: 6.0,
            is_captain: false
          },
          %{
            player_id: 104,
            name: "Robin Le Normand",
            position: 2,
            expected_points: 5.9,
            is_captain: false
          },
          %{
            player_id: 105,
            name: "Dani Carvajal",
            position: 2,
            expected_points: 6.3,
            is_captain: false
          },
          %{player_id: 106, name: "Pedri", position: 3, expected_points: 7.1, is_captain: false},
          %{
            player_id: 107,
            name: "Fabian Ruiz",
            position: 3,
            expected_points: 6.8,
            is_captain: true
          },
          %{
            player_id: 108,
            name: "Mikel Merino",
            position: 3,
            expected_points: 6.2,
            is_captain: false
          },
          %{
            player_id: 109,
            name: "Dani Olmo",
            position: 3,
            expected_points: 7.4,
            is_captain: false
          },
          %{
            player_id: 110,
            name: "Alvaro Morata",
            position: 4,
            expected_points: 6.9,
            is_captain: false
          },
          %{
            player_id: 111,
            name: "Mikel Oyarzabal",
            position: 4,
            expected_points: 7.0,
            is_captain: false
          }
        ],
        captain_id: 107,
        total_points: 78.5,
        excluded: [
          %{player_id: 112, name: "Gavi", reason: "lesión de tobillo (3 semanas)"}
        ]
      },
      alerts: [
        "🚨 PRESUPUESTO EN ROJO: si sigues en negativo cuando arranca la jornada, NO PUNTÚAS. Vende o ajusta ya.",
        "⚡ 1 clausulazo(s) pagables detectados: son compra inmediata, primero que llega se lo lleva.",
        "🔄 En venta pero titulares en tu mejor once: Koke. Retíralos del mercado o perderás sus puntos."
      ]
    }

    persisted = Mister.Reports.persist!(report_map)
    persisted = Repo.preload(persisted, :actions)

    # persist! preserva el orden por prioridad; recargamos para asegurar IDs frescos
    actions =
      ReportAction
      |> where([a], a.daily_report_id == ^persisted.id)
      |> order_by(asc: :id)
      |> Repo.all()

    %{persisted | actions: actions}
  end
end
