defmodule Mister.Client do
  @moduledoc """
  Cliente HTTP para mister.mundodeportivo.com.

  Todos los endpoints conocidos son `POST`. La autenticación va vía cookies
  (`token=` vida corta + `refresh-token=` vida larga), igual que el navegador:
  la cabecera `x-auth` NO es necesaria para el backend (verificado
  empíricamente; con ambas cookies el servidor responde 200 con contenido
  real, sin ellas redirige a /new-onboarding).

  Los valores se configuran en `dev.secret.exs` / runtime:

      config :mister, :static_token, "<JWT corto>"          # cookie `token=`
      config :mister, :static_refresh_token, "<JWT largo>"  # cookie `refresh-token=`
      config :mister, :x_auth, "<hash>"                     # cabecera para /ajax/sw/*

  PENDIENTE: cuando se implemente el refresco automático en `Mister.Auth`,
  inyectar aquí el token vigente del GenServer en lugar de los estáticos.

  Nota de eficiencia: `/ajax/sw/players` es una petición por jugador — no se
  llama para todo el mercado, solo para candidatos ya filtrados de forma barata
  desde el HTML.
  """

  require Logger

  @doc "Listado de mercado: jugadores libres + rivales clausulables (HTML)."
  def fetch_market, do: fetch_html("/market")

  @doc "Plantilla propia completa (HTML)."
  def fetch_team, do: fetch_html("/team")

  @doc "Clasificación de la liga (HTML)."
  def fetch_standings, do: fetch_html("/standings")

  @doc """
  Detalle completo de un jugador (JSON): precio, cláusula, `values_chart`,
  puntos por jornada, estado físico (`status`/`injury`), próximo rival.
  """
  def player_detail(player_id, slug \\ "") do
    fetch_json("/ajax/sw/players", post: "players", id: player_id, slug: slug, comments: 0)
  end

  @doc "Detalle de un usuario/rival concreto (JSON)."
  def user_detail(user_id, slug \\ "") do
    fetch_json("/ajax/sw/users", post: "users", id: user_id, slug: slug, comments: 0)
  end

  ## Internals

  defp fetch_html(path) do
    case request(path) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Mister.Client: #{path} respondió #{status}")
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_json(path, form) do
    case request(path, form: form) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.error("Mister.Client: #{path} respondió #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(path, opts \\ []) do
    with {:ok, cookie} <- auth_cookie() do
      base_url = Application.fetch_env!(:mister, :base_url)

      headers =
        [
          {"cookie", cookie},
          {"origin", base_url},
          {"partial-request", "true"},
          {"x-requested-with", "XMLHttpRequest"}
        ] ++ x_auth_header()

      req_opts = [
        url: base_url <> path,
        headers: headers,
        form: Keyword.get(opts, :form, []),
        retry: :transient,
        connect_options: [timeout: 10_000],
        receive_timeout: 15_000
      ]

      case Req.post(req_opts) do
        {:ok, %Req.Response{} = resp} ->
          debug_dump(path, resp)
          {:ok, resp}

        error ->
          error
      end
    end
  end

  # Si `:debug_dump` está activo (dev), vuelca el cuerpo crudo de cada
  # respuesta a tmp/debug/ para depurar los parsers.
  defp debug_dump(path, %Req.Response{status: status, body: body}) do
    if Application.get_env(:mister, :debug_dump, false) do
      dir = Path.join([File.cwd!(), "tmp", "debug"])
      File.mkdir_p!(dir)

      stamp = System.system_time(:millisecond)
      safe_path = path |> String.replace("/", "_") |> String.replace("?", "-")
      ext = if is_map(body), do: "json", else: "html"
      file = Path.join(dir, "#{stamp}-#{safe_path}.#{ext}")

      content = if is_map(body), do: Jason.encode!(body), else: body
      File.write!(file, content)
      Logger.debug("Mister.Client: respuesta volcada en #{file} (status #{status})")
    end

    :ok
  end

  @doc """
  Saldo del usuario (actual y proyectado) desde el estado embebido en la
  página completa de `/market` (`var _FG_cfg = {...}` → `user.balance`).

  Requiere petición completa (sin cabecera `partial-request`): el fragmento
  AJAX no incluye el `_FG_cfg`.
  """
  def fetch_balance do
    with {:ok, cookie} <- auth_cookie() do
      base_url = Application.fetch_env!(:mister, :base_url)

      req_opts = [
        url: base_url <> "/market",
        headers: [{"cookie", cookie}, {"x-requested-with", "XMLHttpRequest"}] ++ x_auth_header(),
        retry: :transient,
        connect_options: [timeout: 10_000],
        receive_timeout: 15_000
      ]

      with {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
             Req.post(req_opts),
           {:ok, cfg} <- extract_fg_cfg(body),
           %{} = bal <- get_in(cfg, ["user", "balance"]) do
        {:ok,
         %{
           current: bal["current"] || 0,
           future: bal["future"] || 0,
           max_debt: bal["maxDebt"] || 0
         }}
      else
        {:ok, %Req.Response{status: status}} ->
          Logger.error("Mister.Client: /market (completa) respondió #{status}")
          {:error, {:http_status, status}}

        error ->
          error
      end
    end
  end

  # Extrae y decodifica el JSON de `var _FG_cfg = {...};`
  defp extract_fg_cfg(body) do
    case Regex.run(~r/var _FG_cfg = (\{.*?\});/s, body, capture: :all_but_first) do
      [json] ->
        Jason.decode(json)

      [] ->
        {:error, :fg_cfg_not_found}
    end
  catch
    _, _ -> {:error, :fg_cfg_decode_failed}
  end

  # Cookie de autenticación con el mismo formato que envía el navegador:
  # "token=<JWT>; refresh-token=<JWT>". El `refresh-token` es opcional pero
  # sin él el servidor redirige a /new-onboarding.
  defp auth_cookie do
    case Application.get_env(:mister, :static_token) do
      token when is_binary(token) and token != "" ->
        {:ok, "token=" <> token <> refresh_part()}

      _ ->
        {:error, :not_authenticated}
    end
  end

  defp refresh_part do
    case Application.get_env(:mister, :static_refresh_token) do
      refresh when is_binary(refresh) and refresh != "" ->
        "; refresh-token=" <> refresh

      _ ->
        ""
    end
  end

  # Los endpoints `/ajax/sw/*` exigen la cabecera `x-auth` (401 sin ella);
  # las páginas HTML no la necesitan. El valor es estable por sesión/cuenta:
  # se copia del navegador y se configura como `:x_auth`.
  defp x_auth_header do
    case Application.get_env(:mister, :x_auth) do
      value when is_binary(value) and value != "" -> [{"x-auth", value}]
      _ -> []
    end
  end
end
