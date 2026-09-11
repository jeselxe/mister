defmodule MisterWeb.Components.FormationPitch do
  @moduledoc """
  Campo de fútbol visual para la alineación recomendada (sección 12 del spec).

  Renderiza un campo verde con rayas, una fila por línea (delanteros arriba,
  portero abajo), avatar circular por jugador con sus puntos esperados y
  badge dorado "C" para el capitán.

  El `lineup` puede llegar con claves átomo (recién calculado) o string
  (recién cargado de Postgres, donde el campo `:map` se serializa a JSON),
  así que el acceso a claves es tolerante a ambos formatos.
  """
  use MisterWeb, :html

  attr :id, :string, required: true
  attr :lineup, :map, default: nil

  def pitch(assigns)

  def pitch(%{lineup: nil} = assigns) do
    ~H"""
    <div
      id={@id}
      class="flex h-64 items-center justify-center rounded-2xl border border-dashed border-white/30 bg-slate-800/60 text-sm text-slate-400"
    >
      Sin alineación disponible todavía
    </div>
    """
  end

  def pitch(assigns) do
    %{lineup: lineup} = assigns

    assigns =
      assign(assigns,
        formation: get_key(lineup, :formation),
        rows: rows(lineup),
        total_points: get_key(lineup, :total_points)
      )

    ~H"""
    <div id={@id} class="overflow-hidden rounded-2xl shadow-lg ring-1 ring-black/20">
      <div
        class="relative bg-emerald-700 px-4 pb-4 pt-5"
        style="background-image: repeating-linear-gradient(90deg, rgb(4 120/0.35) 0 3rem, transparent 3rem 6rem)"
      >
        <%!-- líneas centrales decorativas --%>
        <div class="pointer-events-none absolute inset-x-8 top-1/2 h-px bg-white/15"></div>
        <div class="pointer-events-none absolute left-1/2 top-1/2 h-20 w-20 -translate-x-1/2 -translate-y-1/2 rounded-full border border-white/15">
        </div>

        <div class="relative mb-3 flex items-center justify-between">
          <span class="rounded-full bg-black/30 px-2.5 py-1 text-xs font-bold tracking-wide text-white">
            {@formation}
          </span>
          <span class="text-xs font-medium text-emerald-100">
            Total esperado: <span class="font-bold text-white">{fmt_pts(@total_points)}</span>
            pts <span class="ml-1 opacity-75">(con bonus capitán x2)</span>
          </span>
        </div>

        <div class="relative flex flex-col gap-3">
          <div
            :for={{players, row_index} <- row_items(@rows)}
            class="flex justify-center gap-2 sm:gap-3"
          >
            <div :for={player <- players} class="w-16 text-center flex flex-col sm:w-20">
              <div class="relative mx-auto">
                <div class="h-11 w-11 overflow-hidden rounded-full shadow-md ring-2 transition-transform hover:scale-110 sm:h-12 sm:w-12">
                  <img
                    src={photo_url(get_key(player, :player_id))}
                    alt={get_key(player, :name)}
                    class="h-full w-full bg-slate-200 object-cover"
                  />
                </div>
                <span
                  :if={get_key(player, :is_captain)}
                  class="absolute -right-1 -top-1 flex h-5 w-5 items-center justify-center rounded-full bg-gradient-to-br from-amber-300 to-yellow-600 text-[10px] font-black text-amber-950 shadow"
                >
                  C
                </span>
              </div>
              <p
                class="mt-1 truncate text-[11px] font-semibold leading-tight text-white"
                title={get_key(player, :name)}
              >
                {last_name(get_key(player, :name))}
              </p>
              <p class="text-[11px] font-bold text-emerald-200">
                {fmt_pts(get_key(player, :expected_points))}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## Internals

  # Divide la plantilla en filas (arriba → abajo): delanteros, medios,
  # defensas, portero, agrupando por la demarcación real de cada jugador
  # (1=PT, 2=DF, 3=MD, 4=DC) en lugar de fiarnos del orden de la lista.
  defp rows(lineup) do
    players = get_key(lineup, :players) || []
    by_pos = Enum.group_by(players, fn p -> pos_int(get_key(p, :position)) end)

    fwd = by_pos[4] || []
    mid = by_pos[3] || []
    defs = by_pos[2] || []
    gk = by_pos[1] || []

    if fwd == [] and mid == [] and defs == [] and gk == [] do
      [players]
    else
      [fwd, mid, defs, gk]
    end
  end

  defp pos_int(p) when is_integer(p), do: p

  defp pos_int(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp pos_int(_), do: nil

  # Filtra filas vacías pero conserva el índice original como clave estable.
  defp row_items(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reject(fn {row, _i} -> row == [] end)
  end

  defp photo_url(player_id) when is_integer(player_id),
    do: "https://cdn-mister.mundodeportivo.com/file/cdn-common/players/#{player_id}.png"

  defp photo_url(player_id) when is_binary(player_id) do
    case Integer.parse(player_id) do
      {id, _} -> photo_url(id)
      _ -> nil
    end
  end

  defp photo_url(_), do: nil

  defp last_name(name) when is_binary(name) do
    name
    |> String.split(~r{\s+}, trim: true)
    |> Enum.filter(&(&1 != "💥"))
    |> List.last() || name
  end

  defp last_name(other), do: to_string(other)

  defp fmt_pts(nil), do: "-"
  defp fmt_pts(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp fmt_pts(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt_pts(other), do: to_string(other)

  # Acceso tolerante a claves átomo/string (JSON round-trip).
  defp get_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end
end
