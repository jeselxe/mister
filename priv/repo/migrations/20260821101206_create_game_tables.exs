defmodule Mister.Repo.Migrations.CreateGameTables do
  use Ecto.Migration

  def change do
    create table(:players) do
      add :mister_id, :integer, null: false
      add :name, :string, null: false
      # 1=GK 2=DEF 3=MID 4=FWD
      add :position, :integer, null: false
      add :team_id, :integer
      add :season_avg, :float
      add :status, :string

      timestamps()
    end

    create unique_index(:players, [:mister_id])

    create table(:price_snapshots) do
      add :player_id, references(:players), null: false
      add :price, :integer, null: false
      add :clause_value, :integer
      add :captured_at, :date, null: false

      timestamps()
    end

    create unique_index(:price_snapshots, [:player_id, :captured_at])

    create table(:squad_memberships) do
      add :player_id, references(:players), null: false
      # "me" | "rival"
      add :owner_type, :string, null: false
      add :owner_mister_id, :string
      add :owner_name, :string
      add :in_lineup, :boolean, default: false
      add :for_sale, :boolean, default: false
      add :recorded_at, :date, null: false

      timestamps()
    end

    create index(:squad_memberships, [:player_id, :recorded_at])

    create table(:market_listings) do
      add :player_id, references(:players), null: false
      add :price, :integer, null: false
      add :is_public, :boolean, default: true
      add :ends_at, :utc_datetime
      add :seen_at, :date, null: false

      timestamps()
    end

    create index(:market_listings, [:player_id, :seen_at])

    create table(:daily_reports) do
      add :report_date, :date, null: false
      add :budget_summary, :map
      add :buy_recommendations, {:array, :map}
      add :sell_recommendations, {:array, :map}
      add :clause_targets, {:array, :map}
      add :best_lineup, :map
      add :alerts, {:array, :string}, default: []

      timestamps()
    end

    create unique_index(:daily_reports, [:report_date])

    create table(:report_actions) do
      add :daily_report_id, references(:daily_reports), null: false
      # "buy" | "sell" | "clause" | "lineup_change"
      add :kind, :string, null: false
      add :player_id, references(:players)
      add :description, :string, null: false
      add :suggested_amount, :integer
      # pending | done | dismissed
      add :status, :string, default: "pending"

      timestamps()
    end

    create index(:report_actions, [:daily_report_id])
  end
end
