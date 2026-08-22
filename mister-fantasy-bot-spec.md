# Mister Fantasy Bot — Especificación técnica

## 1. Resumen del proyecto

Sistema de **análisis diario** (no bot autónomo que actúa solo) para la liga fantasy de fútbol de Mister (mister.mundodeportivo.com). Cada día genera un informe con:

- Jugadores a fichar y cuánto pujar
- Jugadores a poner en venta
- Clausulazos rentables detectados
- Alineación óptima recomendada, con capitán

El usuario decide y ejecuta las acciones manualmente en la app de Mister — el sistema **no puja ni compra automáticamente** (para evitar riesgo de baneo por comportamiento no humano, y porque el usuario prefiere mantener el control final).

## 2. Stack técnico

- **Backend:** Elixir / Phoenix / Phoenix LiveView
- **Jobs programados:** Oban (cron diario + jobs de renovación de auth)
- **Base de datos:** PostgreSQL vía Ecto
- **Scraping HTML:** Floki
- **Cliente HTTP:** Req
- **Despliegue:** Docker + Caddy como reverse proxy (mismo patrón que el resto de proyectos del usuario)

## 3. Autenticación

**Método de login: Sign in with Apple (OAuth social).** No es un login usuario/contraseña automatizable con una simple petición POST.

**Estrategia:**
1. **Login inicial manual, una sola vez.** El usuario inicia sesión en el navegador y captura la sesión completa (cookies/tokens).
2. Se detectaron dos tokens con vidas distintas:
   - `token` — vida corta, es el que se usa en la cabecera `X-Auth` (o cookie) para las peticiones normales.
   - `refresh-token` — vida muy larga (años). Contiene un campo `refresh` identificador.
3. **Pendiente de capturar:** la petición real de refresco de token (probablemente algo como `POST /ajax/auth/refresh`, path exacto sin confirmar). Sin esto, el `Mister.Auth` no puede renovar automáticamente y habrá que ir renovando `token` a mano cuando caduque.
4. Solo si el `refresh-token` se invalida (cambio de contraseña de Apple, revocación de sesión) habrá que repetir el login manual.

**Esqueleto ya escrito** (pendiente de completar `do_refresh/1` en cuanto se capture el endpoint real):

```elixir
defmodule Mister.Auth do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def current_token, do: GenServer.call(__MODULE__, :get_token)

  def init(_) do
    refresh_token = Application.fetch_env!(:mister, :refresh_token)
    {:ok, token, exp} = do_refresh(refresh_token)
    schedule_refresh(exp)
    {:ok, %{token: token, refresh_token: refresh_token, exp: exp}}
  end

  def handle_call(:get_token, _from, state), do: {:reply, state.token, state}

  def handle_info(:refresh, state) do
    {:ok, token, exp} = do_refresh(state.refresh_token)
    schedule_refresh(exp)
    {:noreply, %{state | token: token, exp: exp}}
  end

  defp schedule_refresh(exp) do
    ms_until_refresh = max((exp - System.system_time(:second) - 120) * 1000, 1_000)
    Process.send_after(self(), :refresh, ms_until_refresh)
  end

  defp do_refresh(_refresh_token) do
    # PENDIENTE: implementar en cuanto se capture la petición real de refresh
    raise "not implemented yet"
  end
end
```

**Seguridad:** el `refresh-token` y demás credenciales van en variables de entorno / secretos de Docker — nunca en el repositorio.

## 4. Endpoints descubiertos (mister.mundodeportivo.com)

Todos son `POST`. Autenticación vía cabecera `X-Auth` + cookies de sesión.

| Endpoint | Devuelve | Uso |
|---|---|---|
| `/market` | HTML | Listado de mercado: jugadores libres + jugadores de rivales clausulables |
| `/team` | HTML | Tu plantilla completa (titulares, banquillo, en venta) |
| `/standings` | HTML | Clasificación de la liga: id, slug, valor de equipo y puntos de cada participante |
| `/ajax/sw/players` (body: `post=players&id=<id>&slug=<slug>&comments=0`) | JSON | Detalle completo de un jugador: precio, cláusula, histórico diario de valor (`values_chart`), puntos por jornada, estado físico (`status`/`injury`), próximo rival |
| `/ajax/sw/users` (body: `post=users&id=<id>&slug=<slug>&comments=0`) | JSON | Detalle de un usuario/rival concreto |

**Nota de eficiencia:** `/ajax/sw/players` es una petición por jugador — no se llama para todo el mercado, solo para candidatos ya filtrados de forma barata desde el HTML (tendencia visible, ratio precio/puntos, o marcados como `hot_clause?`).

## 5. Reglas de negocio del juego

- **Presupuesto en rojo:** se puede estar en números rojos, pero **si sigues en negativo cuando arranca la jornada, no puntúas esa jornada.** Es la alerta de mayor prioridad del informe.
- **Puja máxima (fichajes de mercado):** depende de la configuración de la liga. Esta liga usa **saldo + 25% del valor del equipo**. (El sistema soporta también `balance_only`, `+50%` y `unlimited` como configuración, pero el valor por defecto es `+25%`.)
- **Clausulazos:** son **compra inmediata** pagando el precio de la cláusula directamente, **sin pasar por el mercado ni por pujas**. Por tanto:
  - Solo se puede usar el **saldo real disponible**, nunca el bonus de +25% (ese bonus es exclusivo de las pujas de mercado).
  - Es "primero que llega, se lo lleva" — cualquier participante de la liga puede ejecutarlo en cuanto lo vea, así que estas oportunidades se marcan con urgencia alta en el informe.
- **Venta de jugadores:** se ponen "en venta" y **la banca hace una oferta al día** (normalmente de madrugada) a un precio **aleatorio entre el 95% y el 105%** del valor de mercado del jugador. No es una venta inmediata a precio fijo — hay que tratarlo como un rango (pesimista/esperado/optimista), no un número único.

## 6. Modelo de datos (Ecto / Postgres)

```elixir
create table(:players) do
  add :mister_id, :integer, null: false
  add :name, :string, null: false
  add :position, :integer, null: false # 1=GK 2=DEF 3=MID 4=FWD
  add :team_id, :integer
  add :season_avg, :float
  add :status, :string
  timestamps()
end
create unique_index(:players, [:mister_id])

create table(:price_snapshots) do
  add :player_id, references(:players), null: false
  add :price, :integer, null: false
  add :clause_value, :integer
  add :captured_at, :date, null: false
end
create unique_index(:price_snapshots, [:player_id, :captured_at])

create table(:squad_memberships) do
  add :player_id, references(:players), null: false
  add :owner_type, :string, null: false # "me" | "rival"
  add :owner_mister_id, :string
  add :owner_name, :string
  add :in_lineup, :boolean, default: false
  add :for_sale, :boolean, default: false
  add :recorded_at, :date, null: false
end

create table(:market_listings) do
  add :player_id, references(:players), null: false
  add :price, :integer, null: false
  add :is_public, :boolean, default: true
  add :ends_at, :utc_datetime
  add :seen_at, :date, null: false
end

create table(:daily_reports) do
  add :report_date, :date, null: false
  add :budget_summary, :map
  # NOTA: son LISTAS de mapas, no objetos — el tipo correcto en Ecto es
  # {:array, :map} (jsonb[] en Postgres). Con :map el cast falla al persistir.
  add :buy_recommendations, {:array, :map}
  add :sell_recommendations, {:array, :map}
  add :clause_targets, {:array, :map}
  add :best_lineup, :map
  add :alerts, {:array, :string}, default: []
  timestamps()
end
create unique_index(:daily_reports, [:report_date])

create table(:report_actions) do
  add :daily_report_id, references(:daily_reports), null: false
  add :kind, :string, null: false # "buy" | "sell" | "clause" | "lineup_change"
  add :player_id, references(:players)
  add :description, :string, null: false
  add :suggested_amount, :integer
  add :status, :string, default: "pending" # pending | done | dismissed
  timestamps()
end
```

Se guarda snapshot diario propio de precio aunque Mister ya da histórico (`values_chart`) porque permite cruzar **decisiones tomadas** con la evolución real después — eso Mister no lo da.

## 7. Parsers HTML (Floki)

`Mister.MarketParser` y `Mister.PlayerRowParser` comparten estructura porque el `<li>` de un jugador es prácticamente idéntico en `/market` y `/team`. Extraen: `player_id`, `name`, `price`, `trend` (según clase `.value-arrow.green/red`), `season_avg`, `matchday_points`, `hot_clause?` (presencia de `.clauses-ranking-emoji`), `in_lineup?` (clase `in-lineup`), `for_sale?`, `owner_id`.

`Mister.StandingsParser` extrae de `/standings`: `user_id`, `slug`, `name`, `points`, `squad_value` — de aquí sale el censo completo de la liga (para consultar rivales concretos vía `/ajax/sw/users` si hace falta contexto de su situación de presupuesto).

## 8. Motor de presupuesto

```elixir
defmodule Mister.BudgetEngine do
  def available_budget(current_balance, team_value, sale_candidates, bid_rule \\ :balance_plus_25) do
    projected_from_sales = sale_candidates |> Enum.map(& &1.expected_sale_price) |> Enum.sum()

    %{
      # para CLAUSULAZOS: solo esto, nunca el bonus de +25%
      real_now: current_balance,
      real_projected: current_balance + projected_from_sales,

      # para PUJAS de mercado: aquí sí aplica el bonus de la liga
      bid_allowed_now: max_bid_allowed(current_balance, team_value, bid_rule),
      bid_allowed_projected: max_bid_allowed(current_balance + projected_from_sales, team_value, bid_rule)
    }
  end

  defp max_bid_allowed(balance, team_value, :balance_plus_25), do: balance + team_value * 0.25
  defp max_bid_allowed(balance, _team_value, :balance_only), do: max(balance, 0)
end

defmodule Mister.SaleEstimator do
  def expected_range(market_price) do
    %{
      pessimistic: round(market_price * 0.95),
      expected: market_price,
      optimistic: round(market_price * 1.05)
    }
  end
end
```

## 9. Detector de clausulazos

Los datos de cláusula de jugadores rivales ya vienen en el HTML de `/market` (sección de rivales clausulables) y en el JSON de `/ajax/sw/players`, así que no hace falta explorar plantillas rivales completas para esto.

```elixir
defmodule Mister.ClauseDetector do
  def find_opportunities(player_details, real_balance) do
    player_details
    |> Enum.filter(&has_owner?/1)
    |> Enum.map(&score/1)
    |> Enum.filter(&(&1.clause_price <= real_balance))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.map(&Map.put(&1, :urgency, :high))
  end

  defp has_owner?(%{"owner" => %{"id" => id}}), do: not is_nil(id)
  defp has_owner?(_), do: false

  defp score(detail) do
    player = detail["player"] || detail
    clause = player["clause"]
    avg = player["avg"] || 0.0

    %{
      player_id: player["id"],
      name: player["name"],
      clause_price: clause["value"],
      value_per_million: avg / max(clause["value"] / 1_000_000, 0.1),
      score: avg * 10 - clause["value"] / 1_000_000
    }
  end
end
```

La fórmula de `score` es un punto de partida simple, pensada para calibrarse con datos reales de temporada.

## 10. Optimizador de alineación (con capitán y exclusión de bajas)

Formaciones soportadas: 3-4-3, 3-5-2, 4-3-3, 4-4-2, 4-5-1, 5-3-2, 5-4-1.

**Capitán:** el de mayor puntuación esperada dentro del once elegido (el x2 solo tiene sentido sobre quien juega). El total del informe ya incluye el bonus del capitán.

**Exclusión por lesión/sanción:** en el JSON de `/ajax/sw/players`, el campo `status` vale `"injury"` para lesionados, con detalle en `injury: {category, description, duration}`. No se ha confirmado aún el valor exacto para sanciones, así que el filtro usa **lista blanca** (`nil`, `""`, `"ok"` = disponible; cualquier otro valor = no disponible) en vez de una lista cerrada de estados "malos" — más seguro ante estados nuevos no vistos todavía.

**Limitación conocida:** el filtro de disponibilidad solo puede aplicarse a jugadores de los que ya se tiene el detalle cargado (`/ajax/sw/players`). Actualmente solo se pide detalle de candidatos "calientes" (mercado con tendencia, `hot_clause?`), no de toda la plantilla — **pendiente de decidir** si el job diario debe pedir detalle de los 11-15 titularizables siempre, para que el filtro de bajas cubra a toda la plantilla.

```elixir
defmodule Mister.LineupOptimizer do
  @formations [
    {3, 4, 3}, {3, 5, 2}, {4, 3, 3}, {4, 4, 2},
    {4, 5, 1}, {5, 3, 2}, {5, 4, 1}
  ]

  @available_statuses [nil, "", "ok"]

  def best_lineup(squad, player_details) do
    details_by_id = Map.new(player_details, &{&1["player"]["id"], &1["player"]})
    expected_points = build_expected_points_map(squad, details_by_id)

    {available, unavailable} = Enum.split_with(squad, &available?(&1, details_by_id))

    by_position =
      available
      |> Enum.group_by(& &1.position)
      |> Enum.map(fn {pos, players} ->
        {pos, Enum.sort_by(players, &Map.get(expected_points, &1.player_id, 0), :desc)}
      end)
      |> Map.new()

    result =
      @formations
      |> Enum.map(&build_for_formation(&1, by_position, expected_points))
      |> Enum.filter(& &1)
      |> Enum.max_by(& &1.total_points, fn -> nil end)

    Map.put(result, :excluded, format_excluded(unavailable, details_by_id))
  end

  defp build_for_formation({def_n, mid_n, fwd_n}, by_position, expected_points) do
    gk = Enum.take(Map.get(by_position, 1, []), 1)
    def_ = Enum.take(Map.get(by_position, 2, []), def_n)
    mid = Enum.take(Map.get(by_position, 3, []), mid_n)
    fwd = Enum.take(Map.get(by_position, 4, []), fwd_n)

    total_needed = 1 + def_n + mid_n + fwd_n
    picked = gk ++ def_ ++ mid ++ fwd

    if length(picked) == total_needed do
      picked_with_points =
        Enum.map(picked, &Map.put(&1, :expected_points, Map.get(expected_points, &1.player_id, 0)))

      captain = Enum.max_by(picked_with_points, & &1.expected_points)
      picked_with_captain =
        Enum.map(picked_with_points, &Map.put(&1, :is_captain, &1.player_id == captain.player_id))

      base_total = picked_with_points |> Enum.map(& &1.expected_points) |> Enum.sum()
      total_with_captain_bonus = base_total + captain.expected_points

      %{
        formation: "#{def_n}-#{mid_n}-#{fwd_n}",
        players: picked_with_captain,
        captain_id: captain.player_id,
        total_points: total_with_captain_bonus
      }
    end
  end

  defp available?(player, details_by_id) do
    case Map.get(details_by_id, player.player_id) do
      nil -> true
      detail -> status(detail) in @available_statuses
    end
  end

  defp status(detail), do: get_in(detail, ["player", "status"]) || detail["status"]

  defp reason(detail) do
    injury = get_in(detail, ["player", "injury"]) || detail["injury"]
    case injury do
      %{"description" => desc, "duration" => dur} -> "#{desc} (#{dur})"
      _ -> status(detail) || "no disponible"
    end
  end

  defp format_excluded(unavailable, details_by_id) do
    Enum.map(unavailable, fn p ->
      detail = Map.get(details_by_id, p.player_id)
      %{player_id: p.player_id, name: p.name, reason: reason(detail)}
    end)
  end

  defp build_expected_points_map(squad, details_by_id) do
    Map.new(squad, fn p ->
      {p.player_id, expected_points_for(p, Map.get(details_by_id, p.player_id))}
    end)
  end

  defp expected_points_for(%{season_avg: avg}, nil), do: avg || 0.0
  defp expected_points_for(_p, detail) do
    player = detail["player"] || detail
    recent = (player["points"] || []) |> Enum.filter(& &1["points"]["points"]) |> Enum.take(-5)
    if recent == [] do
      player["avg"] || 0.0
    else
      recent |> Enum.map(& &1["points"]["points"]) |> Enum.sum() |> Kernel./(length(recent))
    end
  end
end
```

## 11. Job diario (Oban)

```elixir
defmodule Mister.Workers.DailyAnalysis do
  use Oban.Worker, queue: :mister, max_attempts: 3

  alias Mister.{Client, MarketParser, PlayerRowParser, BudgetEngine, ClauseDetector, LineupOptimizer, Reports}

  @impl Oban.Worker
  def perform(_job) do
    with {:ok, market_html} <- Client.fetch_market(),
         {:ok, team_html} <- Client.fetch_team() do

      market_players = MarketParser.parse(market_html)
      my_squad = PlayerRowParser.parse_all(team_html)
      squad_summary = PlayerRowParser.parse_squad_summary(team_html)

      buy_candidates = market_players |> Enum.filter(&interesting?/1)
      hot_own_players = my_squad |> Enum.filter(& &1.hot_clause?)

      details =
        (buy_candidates ++ hot_own_players)
        |> Enum.map(& &1.player_id)
        |> Enum.uniq()
        |> Enum.map(&Client.player_detail/1)

      budget = BudgetEngine.available_budget(squad_summary.balance, squad_summary.total_value, my_squad)
      clause_targets = ClauseDetector.find_opportunities(details, budget.real_projected)
      lineup = LineupOptimizer.best_lineup(my_squad, details)

      report = Reports.build(%{
        budget: budget,
        buy_candidates: buy_candidates,
        clause_targets: clause_targets,
        lineup: lineup,
        squad_summary: squad_summary
      })

      Reports.persist!(report)
      Phoenix.PubSub.broadcast(Mister.PubSub, "reports", {:new_report, report})
      :ok
    end
  end

  defp interesting?(player) do
    player.trend == :up or (player.season_avg && player.price > 0 &&
      player.season_avg / (player.price / 1_000_000) > 1.5)
  end
end
```

Programado vía `Oban.Plugins.Cron` (`"0 7 * * *"` — 7am cada día).

## 12. Vista web (Phoenix LiveView) — IMPLEMENTADA

Módulos:
- `MisterWeb.ReportLive` (montado en `/`): aviso de presupuesto en rojo, tarjetas de presupuesto (saldo real / proyectado / puja máx actual / proyectada), clausulazos pagables, fichajes recomendados, ventas con rango pesimista/esperado/optimista, checklist marcable (`complete/dismiss/undo_action`) y botón "Ejecutar análisis ahora" que encola el job Oban bajo demanda.
- `MisterWeb.Components.FormationPitch`: campo visual con CSS (césped rayado, filas por línea FWD→GK derivadas de la formación), avatar circular por jugador con puntos esperados y badge dorado "C" del capitán.

Detalles de implementación:
- Los campos `:map`/array se serializan a JSON al persistir: la vista accede a las claves de forma tolerante (átomo o string).
- La vista se suscribe a `Phoenix.PubSub` (topic `reports`) y se refresca sola al recibir `{:new_report, report}`.
- El checklist persiste el estado entre visitas (`report_actions.status`), y `Reports.persist!/1` lo conserva aunque el informe se regenere.
- Tests: `test/mister_web/live/report_live_test.exs` (estado vacío, render completo, checklist persistente, actualización PubSub, encolado del job).

## 13. Pendientes / decisiones abiertas

1. **Capturar el endpoint real de refresh de token** — sin esto, la renovación de sesión sigue siendo manual.
2. **Decidir si el job diario pide detalle (`/ajax/sw/players`) de toda la plantilla titularizable siempre**, para que el filtro de lesión/sanción cubra a todos los jugadores propios (no solo los "calientes"). Coste: más peticiones por ejecución diaria.
3. **Confirmar el valor exacto de `status` para jugadores sancionados** en el JSON de `/ajax/sw/players` (solo se ha confirmado `"injury"` hasta ahora).
4. **Notificación del informe** — se ha hablado de Telegram/email como complemento a la vista LiveView, sin implementar todavía.
5. **Exploración de plantillas rivales vía `/ajax/sw/users`** — dejado como v2, ya que la detección de clausulazos no lo necesita (esos datos ya están en `/market`); serviría para contexto adicional (rivales con presupuesto ajustado, más propensos a vender barato).
