defmodule Mister.DailyReport do
  @moduledoc "Informe diario de análisis: presupuesto, recomendaciones y alineación."
  use Ecto.Schema
  import Ecto.Changeset

  schema "daily_reports" do
    field :report_date, :date
    field :budget_summary, :map
    field :buy_recommendations, {:array, :map}
    field :sell_recommendations, {:array, :map}
    field :clause_targets, {:array, :map}
    field :best_lineup, :map
    field :alerts, {:array, :string}, default: []

    has_many :actions, Mister.ReportAction

    timestamps()
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :report_date,
      :budget_summary,
      :buy_recommendations,
      :sell_recommendations,
      :clause_targets,
      :best_lineup,
      :alerts
    ])
    |> validate_required([:report_date])
    |> unique_constraint(:report_date)
  end
end
