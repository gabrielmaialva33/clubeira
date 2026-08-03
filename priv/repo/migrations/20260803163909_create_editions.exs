defmodule Clubeira.Repo.Migrations.CreateEditions do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:editions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :code, :citext, null: false
      add :name, :text, null: false
      add :sales_during, :tstzrange, null: false
      add :benefits_during, :tstzrange, null: false
      add :status, :text, null: false, default: "draft"

      timestamps(@timestamps_opts)
    end

    create unique_index(:editions, [:polo_id, :code])
    create unique_index(:editions, [:id, :polo_id], name: :editions_id_polo_uidx)

    create constraint(:editions, :editions_status_check,
             check: "status IN ('draft', 'on_sale', 'active', 'closed', 'cancelled')"
           )

    create constraint(:editions, :editions_sales_during_check,
             check:
               "NOT isempty(sales_during) AND NOT lower_inf(sales_during) AND NOT upper_inf(sales_during) AND lower_inc(sales_during) AND NOT upper_inc(sales_during)"
           )

    create constraint(:editions, :editions_benefits_during_check,
             check:
               "NOT isempty(benefits_during) AND NOT lower_inf(benefits_during) AND NOT upper_inf(benefits_during) AND lower_inc(benefits_during) AND NOT upper_inc(benefits_during)"
           )
  end
end
