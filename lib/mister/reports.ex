defmodule Mister.Reports do
  @moduledoc """
  Persistencia del informe diario.

  `persist!/1` guarda el informe del día (idempotente por fecha) y regenera el
  checklist de acciones (`report_actions`), preservando el estado
  (done/dismissed) de las tareas que ya estaban marcadas. El ensamblado puro
  vive en `Mister.Report`.
  """

  import Ecto.Query

  alias Mister.{DailyReport, Player, Report, ReportAction, Repo}

  @doc """
  Guarda el informe del día y su checklist. Idempotente por fecha: si ya hay
  informe para hoy lo actualiza y regenera las acciones conservando el estado
  de las que coinciden (kind + player + descripción).
  """
  def persist!(report_map) do
    date = report_map.report_date

    previous_statuses =
      case Repo.one(from r in DailyReport, where: r.report_date == ^date, preload: :actions) do
        nil ->
          %{}

        existing ->
          Map.new(existing.actions, fn a ->
            {{a.kind, a.player_id, a.description}, a.status}
          end)
      end

    report = upsert_report!(date, report_map)
    Repo.delete_all(from a in ReportAction, where: a.daily_report_id == ^report.id)

    actions =
      report_map
      |> Report.actions()
      |> Enum.map(fn attrs ->
        attrs =
          attrs
          |> Map.put(:daily_report_id, report.id)
          |> Map.put(:player_id, player_db_id(attrs[:mister_id]))

        status =
          Map.get(previous_statuses, {attrs.kind, attrs.player_id, attrs.description}, "pending")

        attrs = Map.put_new(attrs, :status, status)

        %ReportAction{}
        |> ReportAction.changeset(attrs)
        |> Repo.insert!()
      end)

    # Recargamos para que las columnas JSONB vuelvan con claves string (como en
    # `latest/0`): la vista y el PubSub siempre leen el informe serializado.
    report = Repo.get!(DailyReport, report.id)
    %{report | actions: actions}
  end

  @doc "Último informe guardado, con sus acciones."
  def latest do
    DailyReport
    |> order_by(desc: :report_date)
    |> limit(1)
    |> preload(:actions)
    |> Repo.one()
  end

  ## Internals

  defp upsert_report!(date, report_map) do
    attrs = Map.delete(report_map, :report_date)

    case Repo.one(from r in DailyReport, where: r.report_date == ^date) do
      nil ->
        %DailyReport{}
        |> DailyReport.changeset(Map.put(attrs, :report_date, date))
        |> Repo.insert!()

      existing ->
        existing
        |> DailyReport.changeset(attrs)
        |> Repo.update!()
    end
  end

  defp player_db_id(nil), do: nil

  defp player_db_id(mister_id) do
    case Repo.get_by(Player, mister_id: mister_id) do
      nil -> nil
      player -> player.id
    end
  end
end
