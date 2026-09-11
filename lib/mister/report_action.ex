defmodule Mister.ReportAction do
  @moduledoc """
  Tarea del checklist diario: "buy" | "sell" | "unsell" | "list" |
  "clause" | "lineup_change". Estado: pending | done | dismissed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "report_actions" do
    belongs_to :daily_report, Mister.DailyReport
    field :kind, :string
    belongs_to :player, Mister.Player
    field :description, :string
    field :suggested_amount, :integer
    field :status, :string, default: "pending"

    timestamps()
  end

  def changeset(action, attrs) do
    action
    |> cast(attrs, [:daily_report_id, :kind, :player_id, :description, :suggested_amount, :status])
    |> validate_required([:daily_report_id, :kind, :description])
    |> validate_inclusion(:kind, ["buy", "sell", "unsell", "list", "clause", "lineup_change"])
    |> validate_inclusion(:status, ["pending", "done", "dismissed"])
  end
end
