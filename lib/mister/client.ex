defmodule Mister.Client do
  @moduledoc """
  Cliente HTTP para mister.mundodeportivo.com.

  Todos los endpoints conocidos son `POST`. La autenticación va vía cabecera
  `X-Auth` (token de vida corta gestionado por `Mister.Auth`) más las cookies
  de sesión capturadas en el login manual (`MISTER_COOKIES`).

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
    with {:ok, token} <- auth_token() do
      base_url = Application.fetch_env!(:mister, :base_url)

      headers =
        [{"x-auth", token}]
        |> maybe_add_cookie()

      req_opts = [
        url: base_url <> path,
        headers: headers,
        form: Keyword.get(opts, :form, []),
        retry: :transient,
        connect_options: [timeout: 10_000],
        receive_timeout: 15_000
      ]

      Req.post(req_opts)
    end
  end

  # Token de la sesión gestionada por Mister.Auth; si el GenServer no está
  # activo (refresh endpoint aún sin capturar), se usa un token estático
  # inyectado a mano vía MISTER_STATIC_TOKEN.
  defp auth_token do
    case Mister.Auth.current_token() do
      {:ok, token} -> {:ok, token}
      {:error, :not_authenticated} -> static_token()
    end
  end

  defp static_token do
    case Application.get_env(:mister, :static_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :not_authenticated}
    end
  end

  defp maybe_add_cookie(headers) do
    case Application.get_env(:mister, :cookies) do
      cookies when is_binary(cookies) and cookies != "" ->
        [{"cookie", cookies} | headers]

      _ ->
        headers
    end
  end
end
