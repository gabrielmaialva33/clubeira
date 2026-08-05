defmodule Clubeira.Repo.Migrations.AddPaymentIntentCheckoutAction do
  use Ecto.Migration

  def change do
    alter table(:payment_intents) do
      add :payment_method, :text
      add :next_action, :map, null: false, default: fragment("'{}'::jsonb")
    end

    create constraint(:payment_intents, :payment_intents_payment_method_check,
             check: "payment_method IS NULL OR payment_method IN ('pix')"
           )

    create constraint(:payment_intents, :payment_intents_next_action_check,
             check: "jsonb_typeof(next_action) = 'object'"
           )
  end
end
