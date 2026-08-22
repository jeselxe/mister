defmodule Mister.Store do
  @moduledoc """
  Persistencia del censo diario: jugadores, snapshots de precio,
  membresías de plantilla y listados de mercado.

  Se guarda snapshot diario propio de precio aunque Mister ya da histórico
  (`values_chart`) porque permite cruzar **decisiones tomadas** con la
  evolución real después — eso Mister no lo da.
  """

  import Ecto.Query

  alias Mister.{MarketListing, Player, PriceSnapshot, Repo, SquadMembership}

  @doc """
  Guarda el censo del día a partir de los datos ya parseados.

    * `market_players` — filas de `/market`
    * `my_squad` — filas de `/team`
    * `squad_summary` — `%{balance:, total_value:}` de `/team`

  Los jugadores con `clause_value` conocida guardan snapshot de cláusula.
  Idempotente por día (unique indexes + `on_conflict`).
  """
  def record_daily_census(market_players, my_squad, _squad_summary, date \\ Date.utc_today()) do
    all_rows = Enum.uniq_by(market_players ++ my_squad, & &1.player_id)

    Repo.transaction(fn ->
      players = Enum.map(all_rows, &upsert_player!/1)

      players_by_id = Map.new(players, &{&1.mister_id, &1})

      for row <- my_squad do
        player = Map.fetch!(players_by_id, row.player_id)

        %SquadMembership{}
        |> SquadMembership.changeset(%{
          player_id: player.id,
          owner_type: "me",
          owner_mister_id: row.owner_id,
          in_lineup: row.in_lineup?,
          for_sale: row.for_sale?,
          recorded_at: date
        })
        |> Repo.insert!()
      end

      for row <- market_players do
        player = Map.fetch!(players_by_id, row.player_id)

        %MarketListing{}
        |> MarketListing.changeset(%{
          player_id: player.id,
          price: row.price || 0,
          is_public: is_nil(row.owner_id),
          seen_at: date
        })
        |> Repo.insert!()

        maybe_snapshot(player, row, date)
      end
    end)
  end

  @doc "Último snapshot de precio/cláusula guardado para un jugador."
  def latest_snapshot(player_id) do
    PriceSnapshot
    |> where([s], s.player_id == ^player_id)
    |> order_by([s], desc: s.captured_at)
    |> limit(1)
    |> Repo.one()
  end

  defp upsert_player!(row) do
    %Player{}
    |> Player.changeset(%{
      mister_id: row.player_id,
      name: row.name,
      position: row.position || guess_position(row),
      season_avg: row.season_avg,
      status: nil
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:name, :season_avg, :updated_at]},
      conflict_target: :mister_id
    )
  end

  # Sin data-position en el HTML no conocemos la demarcación; se deja 0 y el
  # detalle JSON (/ajax/sw/players) podrá corregirla más adelante.
  defp guess_position(_row), do: 0

  defp maybe_snapshot(player, row, date) do
    price = row.price || row.clause_value

    if price do
      %PriceSnapshot{}
      |> PriceSnapshot.changeset(%{
        player_id: player.id,
        price: price,
        clause_value: row.clause_value,
        captured_at: date
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:player_id, :captured_at]
      )
    end
  end
end
