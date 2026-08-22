# Mister Fantasy Bot — Todolist

## 🔴 Bloqueantes / alta prioridad

- [ ] **Capturar el endpoint real de refresh de token** (probablemente `POST /ajax/auth/refresh`, path sin confirmar) e implementar `Mister.Auth.do_refresh/1`. Sin esto, la renovación de sesión es manual: cuando caduca el `token`, hay que loguearse a mano y actualizar el secret.
  - Cómo capturar: DevTools → Network → filtrar peticiones justo cuando la app renueva sesión, copiar método/path/body/cabeceras.
- [ ] **Probar el flujo end-to-end con datos reales**: arrancar `mix phx.server` con el token configurado (`MISTER_REFRESH_TOKEN`), pulsar "Ejecutar análisis ahora" y validar que mercado/plantilla/detalles se parsean bien y el informe persiste.
  - [ ] Verificar los selectores de `MarketParser` / `PlayerRowParser` / `StandingsParser` contra el HTML real actual (pueden haber cambiado).
  - [ ] Confirmar formato real de `/ajax/sw/players` para `ClauseDetector` y `LineupOptimizer` (claves anidadas `player`/`clause`/`points`).

## 🟡 Media prioridad

- [ ] **Pedir detalle (`/ajax/sw/players`) de TODA la plantilla titularizable** en el job diario, no solo de los candidatos "calientes", para que el filtro de lesión/sanción cubra a los 15-18 jugadores propios. Coste: ~1 petición por jugador al día (aceptable).
- [ ] **Confirmar el valor exacto de `status` para sancionados** en el JSON de detalle (solo confirmado `"injury"`). El filtro usa lista blanca, así que mientras tanto los sancionados podrían colarse en el once si nunca se pide su detalle.
- [ ] **Fotos reales de jugadores en el campo** (`FormationPitch`): extraer URL del avatar desde el HTML de `/team` o del JSON de detalle, guardarla en `players.avatar_url` (nueva columna + migración) y usar `<img>` en vez de iniciales.
- [ ] **Calibrar la fórmula de score de clausulazos** (`ClauseDetector.score/1`) con datos reales de temporada; hoy es un punto de partida (`avg * 10 - clause/M€`).
- [ ] **Calibrar el umbral de candidatos interesantes** (`interesting?/1` del job): ratio > 1.5 pts/M€ es arbitrario.

## 🟢 Baja prioridad / v2

- [ ] **Notificaciones** (Telegram o email vía Swoosh ya incluido) cuando haya:
  - presupuesto en rojo,
  - clausulazos pagables nuevos,
  - informe diario generado.
- [ ] **Exploración de plantillas rivales** vía `/ajax/sw/users`: contexto de rivales con presupuesto ajustado (más propensos a vender barato). No necesario para clausulazos (los datos vienen en `/market`).
- [ ] **Histórico y evolución**: vista/gráfica con los snapshots diarios de precio (`price_snapshots`) para cruzar decisiones tomadas vs. evolución real.
- [ ] **Despliegue**: Dockerfile + Caddy (mismo patrón que otros proyectos) y secrets en variables de entorno (`MISTER_REFRESH_TOKEN`, credenciales BD).

## ✅ Hecho

- [x] Backend completo: parsers HTML (mercado, plantilla, clasificación), cliente HTTP, motor de presupuesto, detector de clausulazos, optimizador de alineación, estimador de ventas
- [x] Persistencia: censo diario (`Mister.Store`), informes idempotentes por fecha con checklist persistente
- [x] Job diario Oban (cron 7:00 Europe/Madrid) + ejecución manual desde la web
- [x] Migración de Oban (v14) + fix de tipos del informe (`{:array, :map}`)
- [x] Vista LiveView del informe (`ReportLive`) + campo visual (`FormationPitch`)
- [x] Tests de la vista (10) y `mix precommit` limpio
