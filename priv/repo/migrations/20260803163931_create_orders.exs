defmodule Clubeira.Repo.Migrations.CreateOrders do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:orders, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :purchaser_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :order_number, :citext, null: false
      add :idempotency_key, :text, null: false
      add :currency, :string, size: 3, null: false
      add :subtotal_amount, :decimal, precision: 14, scale: 2, null: false
      add :discount_amount, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :total_amount, :decimal, precision: 14, scale: 2, null: false
      add :status, :text, null: false, default: "pending"
      add :placed_at, :timestamptz
      add :cancelled_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create unique_index(:orders, [:id, :polo_id], name: :orders_id_polo_uidx)
    create unique_index(:orders, [:polo_id, :order_number])
    create unique_index(:orders, [:polo_id, :purchaser_user_id, :idempotency_key],
             name: :orders_actor_idempotency_uidx
           )
    create index(:orders, [:purchaser_user_id, :inserted_at])

    create constraint(:orders, :orders_amounts_check,
             check:
               "subtotal_amount >= 0 AND discount_amount >= 0 AND total_amount >= 0 AND total_amount = subtotal_amount - discount_amount"
           )

    create constraint(:orders, :orders_currency_check,
             check: "currency = upper(currency) AND char_length(currency) = 3"
           )

    create constraint(:orders, :orders_status_check,
             check:
               "status IN ('pending', 'awaiting_payment', 'paid', 'cancelled', 'expired', 'refunded')"
           )
  end
end
