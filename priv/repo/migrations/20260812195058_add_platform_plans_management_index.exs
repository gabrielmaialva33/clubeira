defmodule Clubeira.Repo.Migrations.AddPlatformPlansManagementIndex do
  use Ecto.Migration

  def change do
    create index(:platform_plans, [:inserted_at, :id], name: :platform_plans_management_feed_idx)
  end
end
