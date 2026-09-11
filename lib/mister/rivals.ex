defmodule Mister.Rivals do
  @moduledoc """
  Explorador de plantillas rivales (`/standings` + `/ajax/sw/users`).

  Una petición por rival devuelve su plantilla completa (`data.team_now`) con
  el valor de cláusula de cada jugador, que es justo lo que necesita el
  detector de clausulazos.

  `/market` **no basta**: solo muestra jugadores en venta, pero un clausulazo
  se puede pagar sobre cualquier jugador de un rival. Por eso hay que recorrer
  la clasificación y pedir el detalle de cada participante.
  """

  require Logger

  alias Mister.{Client, StandingsParser}

  @doc """
  Jugadores de todos los rivales, normalizados en la forma que consume
  `Mister.ClauseDetector` (mapa con `"player"` → `"owner"`/`"clause"`/`"avg"`).

  `exclude_user_id` deja fuera al propio usuario para no recomendar
  clausulazos sobre jugadores propios.
  """
  def clause_candidates(exclude_user_id \\ nil) do
    case Client.fetch_standings() do
      {:ok, html} ->
        html
        |> StandingsParser.parse()
        |> Enum.reject(&(&1.user_id == normalize_id(exclude_user_id)))
        |> Task.async_stream(&squad_of/1,
          max_concurrency: 4,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, players} -> players
          _ -> []
        end)

      {:error, reason} ->
        Logger.warning("Mister.Rivals: no se pudo leer la clasificación: #{inspect(reason)}")
        []
    end
  end

  defp squad_of(%{user_id: user_id, slug: slug, name: owner_name}) do
    case Client.user_detail(user_id, slug || "") do
      {:ok, %{"team_now" => players}} when is_list(players) ->
        Enum.map(players, &normalize(&1, user_id, owner_name))

      {:ok, _} ->
        []

      {:error, reason} ->
        Logger.warning("Mister.Rivals: plantilla de #{user_id} no disponible: #{inspect(reason)}")
        []
    end
  end

  # Normaliza una fila de `team_now` a la forma de `/ajax/sw/players`, de la
  # que `ClauseDetector` saca owner, cláusula, id, nombre y media. El nombre
  # del dueño lo aporta la clasificación (el `team_now` no lo trae).
  @doc false
  def normalize(player, owner_id, owner_name \\ nil) do
    owner = %{"id" => owner_id(player, owner_id), "name" => owner_name}
    %{"player" => Map.put(player, "owner", owner)}
  end

  defp owner_id(player, fallback) do
    case player["id_uc"] do
      id when is_integer(id) and id > 0 -> id
      _ -> to_int(fallback)
    end
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(_), do: nil

  defp to_int(id) when is_integer(id), do: id

  defp to_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
