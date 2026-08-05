defmodule Clubeira.Repo.Migrations.AddMemberRedemptionHistoryIndex do
  use Ecto.Migration

  def change do
    create index(
             :redemption_attempts,
             [:polo_id, :requesting_user_id, :requested_at, :id],
             name: :redemption_attempts_member_history_idx
           )
  end
end
