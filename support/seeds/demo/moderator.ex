defmodule Clubeira.Seeds.Demo.Moderator do
  @moduledoc false

  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Demo.Staff

  @spec run!() :: map()
  def run! do
    Staff.seed!(
      user_id: id(:moderator_user),
      email_env: "CLUBEIRA_DEMO_MODERATOR_EMAIL",
      email: "moderador.demo@clubeira.local",
      password_env: "CLUBEIRA_DEMO_MODERATOR_PASSWORD",
      password: "clubeira-moderador-local",
      role_key: "review_moderator",
      role_name: "Moderação de avaliações",
      memberships: [
        [
          polo_id: id(:polo_sobral),
          role_id: id(:review_moderator_role_sobral),
          membership_id: id(:moderator_membership_sobral)
        ],
        [
          polo_id: id(:polo_londrina),
          role_id: id(:review_moderator_role_londrina),
          membership_id: id(:moderator_membership_londrina)
        ]
      ]
    )
  end

  defp id(name), do: Ids.fetch!(name)
end
