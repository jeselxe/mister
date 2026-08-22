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
          price: 8_000_000,
          season_avg: 7.2,
          trend: "up",
          suggested_bid: 8_400_000
        }
      ],
      sell_recommendations: [
        %{
          player_id: 4001,
          name: "Iago Aspas",
          market_price: 3_000_000,
          sale_range: %{pessimistic: 2_850_000, expected: 3_000_000, optimistic: 3_150_000}
        }
      ],
      clause_targets: [
        %{
          player_id: 2001,
          name: "Kylian Mbappé",
          clause_price: 20_000_000,
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
        "⚡ 1 clausulazo(s) pagables detectados: son compra inmediata, primero que llega se lo lleva."
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
