defmodule Mister.Repo.Migrations.AddSellHintsToDailyReports do
  use Ecto.Migration

  def change do
    alter table(:daily_reports) do
      add :sell_hints, {:array, :map}
    end
  end
end
