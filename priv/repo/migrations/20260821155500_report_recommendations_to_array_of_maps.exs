defmodule Mister.Repo.Migrations.ReportRecommendationsToArrayOfMaps do
  use Ecto.Migration

  # Las recomendaciones (fichajes, ventas, clausulazos) son listas de mapas,
  # no objetos: el esquema original los declaraba como `:map` y fallaba el
  # cast al persistir. En Ecto eso es {:array, :map}, que en Postgres es
  # jsonb[] (un array de jsonb).

  @columns ~w(buy_recommendations sell_recommendations clause_targets)

  def up do
    # Postgres no permite subqueries en la cláusula USING de ALTER TYPE,
    # así que la conversión se hace columna nueva + copia + rename.
    for column <- @columns do
      execute("ALTER TABLE daily_reports ADD COLUMN #{column}_new jsonb[]")
    end

    for column <- @columns do
      execute("""
      UPDATE daily_reports SET #{column}_new =
        CASE
          WHEN #{column} IS NULL THEN NULL
          WHEN jsonb_typeof(#{column}) = 'array'
            THEN COALESCE(ARRAY(SELECT * FROM jsonb_array_elements(#{column})), '{}'::jsonb[])
          ELSE ARRAY[#{column}]
        END
      """)
    end

    for column <- @columns do
      execute("ALTER TABLE daily_reports ALTER COLUMN #{column} DROP DEFAULT")
      execute("ALTER TABLE daily_reports DROP COLUMN #{column}")
      execute("ALTER TABLE daily_reports RENAME COLUMN #{column}_new TO #{column}")
    end
  end

  def down do
    for column <- @columns do
      execute("""
      ALTER TABLE daily_reports
        ALTER COLUMN #{column} DROP DEFAULT,
        ALTER COLUMN #{column} TYPE jsonb USING to_jsonb(#{column})
      """)
    end
  end
end
