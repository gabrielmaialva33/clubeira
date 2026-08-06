defmodule Clubeira.Repo.Migrations.CreatePoloPlaceOpeningPeriods do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:polo_place_opening_periods, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :polo_place_profile_id,
          references(:polo_place_profiles,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :polo_place_opening_periods_profile_fkey,
            on_delete: :restrict
          ),
          null: false

      add :kind, :text, null: false
      add :weekday, :smallint
      add :local_date, :date
      add :opens_at, :time
      add :closes_at, :time
      add :closes_next_day, :boolean, null: false, default: false

      timestamps(@timestamps_opts)
    end

    create index(
             :polo_place_opening_periods,
             [:polo_id, :polo_place_profile_id, :kind, :weekday, :local_date, :opens_at],
             name: :polo_place_opening_periods_profile_idx
           )

    create constraint(:polo_place_opening_periods, :polo_place_opening_periods_shape_check,
             check: """
             (
               kind = 'weekly'
               AND weekday BETWEEN 1 AND 7
               AND local_date IS NULL
               AND opens_at IS NOT NULL
               AND closes_at IS NOT NULL
             )
             OR (
               kind = 'exception_open'
               AND weekday IS NULL
               AND local_date IS NOT NULL
               AND opens_at IS NOT NULL
               AND closes_at IS NOT NULL
             )
             OR (
               kind = 'exception_closed'
               AND weekday IS NULL
               AND local_date IS NOT NULL
               AND opens_at IS NULL
               AND closes_at IS NULL
               AND closes_next_day = false
             )
             """
           )

    create constraint(:polo_place_opening_periods, :polo_place_opening_periods_time_check,
             check: """
             kind = 'exception_closed'
             OR (closes_next_day = false AND opens_at < closes_at)
             OR (closes_next_day = true AND opens_at >= closes_at)
             """
           )

    add_weekly_overlap_constraint()
    add_exception_overlap_constraint()
    enable_tenant_rls(:polo_place_opening_periods)
  end

  defp add_weekly_overlap_constraint do
    execute(
      """
      ALTER TABLE polo_place_opening_periods
      ADD CONSTRAINT polo_place_opening_periods_weekly_overlap_excl
      EXCLUDE USING gist (
        polo_place_profile_id WITH =,
        (
          int4multirange(
            int4range(
              (((weekday - 1) * 1440) + extract(hour FROM opens_at)::integer * 60 + extract(minute FROM opens_at)::integer),
              (((weekday - 1) * 1440) + extract(hour FROM closes_at)::integer * 60 + extract(minute FROM closes_at)::integer + CASE WHEN closes_next_day THEN 1440 ELSE 0 END),
              '[)'
            ),
            int4range(
              (((weekday - 1) * 1440) + extract(hour FROM opens_at)::integer * 60 + extract(minute FROM opens_at)::integer + 10080),
              (((weekday - 1) * 1440) + extract(hour FROM closes_at)::integer * 60 + extract(minute FROM closes_at)::integer + CASE WHEN closes_next_day THEN 1440 ELSE 0 END + 10080),
              '[)'
            )
          )
        ) WITH &&
      )
      WHERE (kind = 'weekly')
      """,
      """
      ALTER TABLE polo_place_opening_periods
      DROP CONSTRAINT polo_place_opening_periods_weekly_overlap_excl
      """
    )
  end

  defp add_exception_overlap_constraint do
    execute(
      """
      ALTER TABLE polo_place_opening_periods
      ADD CONSTRAINT polo_place_opening_periods_exception_overlap_excl
      EXCLUDE USING gist (
        polo_place_profile_id WITH =,
        (
          tsrange(
            local_date::timestamp + COALESCE(opens_at, time '00:00'),
            CASE
              WHEN kind = 'exception_closed' THEN (local_date + 1)::timestamp
              WHEN closes_next_day THEN (local_date + 1)::timestamp + closes_at
              ELSE local_date::timestamp + closes_at
            END,
            '[)'
          )
        ) WITH &&
      )
      WHERE (kind IN ('exception_open', 'exception_closed'))
      """,
      """
      ALTER TABLE polo_place_opening_periods
      DROP CONSTRAINT polo_place_opening_periods_exception_overlap_excl
      """
    )
  end

  defp enable_tenant_rls(table) do
    execute(
      "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY",
      "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY polo_isolation ON #{table}
      FOR ALL
      USING (
        polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
      )
      WITH CHECK (
        polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
      )
      """,
      "DROP POLICY polo_isolation ON #{table}"
    )
  end
end
