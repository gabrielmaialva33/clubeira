defmodule Clubeira.Repo.Migrations.AddPartnerAccessBackofficeIndexes do
  use Ecto.Migration

  def change do
    create index(:polo_memberships, [:polo_id, :inserted_at, :id],
             name: :polo_memberships_backoffice_feed_idx
           )

    create index(:polo_memberships, [:polo_id, :status, :inserted_at, :id],
             name: :polo_memberships_backoffice_status_feed_idx
           )
  end
end
