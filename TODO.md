# Mister Fantasy Bot — Todolist

## 🔴 Bloqueantes / alta prioridad

- [ ] **Capturar el endpoint real de refresh de token** (probablemente `POST /ajax/auth/refresh`, path sin confirmar) e implementar `Mister.Auth.do_refresh/1`. Sin esto, la renovación de sesión es manual: cuando caduca el `token`, hay que loguearse a mano y actualizar el secret.
  - Cómo capturar: DevTools → Network → filtrar peticiones justo cuando la app renueva sesión, copiar método/path/body/cabeceras.
- [ ] **Probar el flujo end-to-end con datos reales**: arrancar `mix phx.server` con el token configurado (`MISTER_REFRESH_TOKEN`), pulsar "Ejecutar análisis ahora" y validar que mercado/plantilla/detalles se parsean bien y el informe persiste.
  - [ ] Verificar los selectores de `MarketParser` / `PlayerRowParser` / `StandingsParser` contra el HTML real actual (pueden haber cambiado).
  - [ ] Confirmar formato real de `/ajax/sw/players` para `ClauseDetector` y `LineupOptimizer` (claves anidadas `player`/`clause`/`points`).

## 🟡 Media prioridad

- [ ] **Confirmar el valor exacto de `status` para sancionados** en el JSON de detalle (solo confirmado `"injury"`). El filtro usa lista blanca, así que mientras tanto los sancionados podrían colarse en el once si nunca se pide su detalle.
- [ ] **Fotos reales de jugadores en el campo** (`FormationPitch`): extraer URL del avatar desde el HTML de `/team` o del JSON de detalle, guardarla en `players.avatar_url` (nueva columna + migración) y usar `<img>` en vez de iniciales.
- [ ] **Calibrar la fórmula de score de clausulazos** (`ClauseDetector.score/1`) con datos reales de temporada; hoy es un punto de partida (`avg * 10 - clause/M€`).
- [ ] **Calibrar el filtro de clausulazos**: `value_per_million >= 1.0` y tope de 12 (`@min_value_per_million` / `@max_targets`) ahora que se recorren todas las plantillas rivales.
- [ ] **Calibrar las pistas de venta** (`Reports.sell_hint_reason/2` y `@max_sell_hints`): los umbrales de media y `growth_7d` son heurísticos.
- [ ] **Calibrar el umbral de puja** (`Mister.Valuation`): ROI `@bid_gain_pct` 8%, dinero `@bid_gain_abs` 250k, suelos `@bid_min_gain_pct` 3% / `@bid_min_gain_abs` 50k, `@bid_pts_per_million` 2.0 y `@bid_min_avg` 2.5.
- [ ] **Calibrar los umbrales de puja** (`Mister.Valuation`): `@bid_gain_pct` (8% de reventa proyectada) y `@bid_pts_per_million` (2.0) son heurísticos; ajustar con resultados reales de la temporada.
- [ ] **Calibrar el horizonte de proyección** (`@horizon_days`, hoy 7 días) y el tope de ±5%/día según cómo se comporte el mercado.

## 🟢 Baja prioridad / v2

- [ ] **Notificaciones** (Telegram o email vía Swoosh ya incluido) cuando haya:
  - presupuesto en rojo,
  - clausulazos pagables nuevos,
  - informe diario generado.
- [ ] **Contexto de rivales vía `/ajax/sw/users`**: ya se usa para clausulazos (`Mister.Rivals`); pendiente cruzar el presupuesto/plantilla de cada rival (más propensos a vender barato) en el informe.
- [ ] **Histórico y evolución**: vista/gráfica con los snapshots diarios de precio (`price_snapshots`) para cruzar decisiones tomadas vs. evolución real.
- [ ] **Despliegue**: Dockerfile + Caddy (mismo patrón que otros proyectos) y secrets en variables de entorno (`MISTER_REFRESH_TOKEN`, credenciales BD).

## ✅ Hecho

- [x] Backend completo: parsers HTML (mercado, plantilla, clasificación), cliente HTTP, motor de presupuesto, detector de clausulazos, optimizador de alineación, estimador de ventas
- [x] Persistencia: censo diario (`Mister.Store`), informes idempotentes por fecha con checklist persistente
- [x] Job diario Oban (cron 7:00 Europe/Madrid) + ejecución manual desde la web
- [x] Migración de Oban (v14) + fix de tipos del informe (`{:array, :map}`)
- [x] Vista LiveView del informe (`ReportLive`) + campo visual (`FormationPitch`)
- [x] Detalle (`/ajax/sw/players`) de todo el mercado y de toda la plantilla: el filtro de lesión/sanción cubre a los 15-18 titulares y los clausulazos ya cargan sus datos
- [x] Pujas separadas de seguimientos, con crecimiento y reventa proyectada (`Mister.Valuation`)
- [x] Cruce ventas ↔ mejor once: un titular en venta pasa a "retirar de la venta" (acción `unsell` + alerta)
- [x] Pistas de a quién **poner en venta** (`sell_hints`): suplentes que no puntúan o pierden valor, con motivo, valor y oferta esperada (acción `list`), limitadas a los huecos libres de venta (máx. 5 en venta)
- [x] Clausulazos de **todas las plantillas rivales** vía `/standings` + `/ajax/sw/users` (`data.team_now`), no solo de `/market`; con filtro de rendimiento y tope
- [x] Deslizador de puja por jugador (hook colocado `.BidSlider`) para ver la ganancia (`reventa esperada − puja`) según lo que pujes, incluso a precio de mercado
- [x] Filas de jugador destiladas: decisión en una línea, deslizador y banda de reventa detrás de un `<details>`, checklist de una línea y rango de venta colapsado
- [x] Endurecido: confirmación en dos pasos para aceptar oferta (irreversible), leyenda de términos y navegación con contadores
- [x] Checklist compacto por jugador (`report_actions.player_name`, migración) en vez de repetir la descripción de cada sección
- [x] Tests de la vista (12), tests unitarios de `Valuation`, `ClauseDetector`, `Reports`, `StandingsParser` y `Rivals`, y `mix precommit` limpio
