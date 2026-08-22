defmodule Mister.Auth do
  @moduledoc """
  Gestión de sesión de Mister (login vía Sign in with Apple).

  - `token` — vida corta, se usa en la cabecera `X-Auth` para las peticiones.
  - `refresh-token` — vida muy larga (años), se obtiene en el login manual
    inicial y se guarda en `MISTER_REFRESH_TOKEN`.

  PENDIENTE: capturar la petición real de refresco de token (probablemente
  `POST /ajax/auth/refresh`, path exacto sin confirmar). Mientras tanto,
  cuando el token caduca hay que renovarlo a mano repitiendo el login manual.
  """
  use GenServer

  require Logger

  def start_link(opts \\ []) do
    if Application.get_env(:mister, :refresh_token) do
      GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
    else
      Logger.warning("Mister.Auth: MISTER_REFRESH_TOKEN no configurado; auth deshabilitada")
      :ignore
    end
  end

  def current_token do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_authenticated}
      pid -> {:ok, GenServer.call(pid, :get_token)}
    end
  end

  @impl true
  def init(_) do
    refresh_token = Application.fetch_env!(:mister, :refresh_token)

    with {:ok, token, exp} <- do_refresh(refresh_token) do
      schedule_refresh(exp)
      {:ok, %{token: token, refresh_token: refresh_token, exp: exp}}
    else
      {:error, reason} ->
        Logger.error("Mister.Auth: no se pudo refrescar el token: #{inspect(reason)}")
        # Reintentar en 5 minutos en lugar de tumbar la app
        Process.send_after(self(), :refresh, 5 * 60 * 1000)
        {:ok, %{token: nil, refresh_token: refresh_token, exp: nil}}
    end
  end

  @impl true
  def handle_call(:get_token, _from, state), do: {:reply, state.token, state}

  @impl true
  def handle_info(:refresh, state) do
    case do_refresh(state.refresh_token) do
      {:ok, token, exp} ->
        schedule_refresh(exp)
        {:noreply, %{state | token: token, exp: exp}}

      {:error, reason} ->
        Logger.error("Mister.Auth: fallo al refrescar token: #{inspect(reason)}")
        Process.send_after(self(), :refresh, 5 * 60 * 1000)
        {:noreply, state}
    end
  end

  defp schedule_refresh(nil), do: :ok

  defp schedule_refresh(exp) do
    ms_until_refresh = max((exp - System.system_time(:second) - 120) * 1000, 1_000)
    Process.send_after(self(), :refresh, ms_until_refresh)
  end

  # PENDIENTE: capturar la petición real de refresco de token. Cuando se
  # conozca el endpoint, implementar un módulo `run/1` que devuelva
  # {:ok, token, expires_at_unix_seconds} y configurarlo en runtime.exs:
  #
  #     config :mister, :token_refresh, {MyApp.AuthRefresh, :run}
  #
  # Mientras tanto devuelve error (con reintento periódico) en vez de tumbar
  # la app: el cliente cae al token estático MISTER_STATIC_TOKEN.
  @spec do_refresh(binary()) :: {:ok, binary(), integer()} | {:error, term()}
  defp do_refresh(refresh_token) do
    case Application.get_env(:mister, :token_refresh) do
      {mod, fun} when is_atom(mod) and is_atom(fun) -> apply(mod, fun, [refresh_token])
      _ -> {:error, :refresh_not_implemented}
    end
  end
end
