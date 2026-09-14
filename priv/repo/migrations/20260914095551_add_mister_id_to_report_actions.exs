defmodule Mister.Repo.Migrations.AddMisterIdToReportActions do
  use Ecto.Migration

  def change do
    alter table(:report_actions) do
      add :mister_id, :integer
    end

    create index(:report_actions, [:daily_report_id, :kind, :mister_id])
  end
end
