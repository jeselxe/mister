defmodule Mister.Repo.Migrations.AddPlayerNameToReportActions do
  use Ecto.Migration

  def change do
    alter table(:report_actions) do
      add :player_name, :string
    end
  end
end
