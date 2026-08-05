defmodule Clubeira.Seeds.Demo.Admin do
  @moduledoc false

  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Demo.Staff

  @spec run!() :: map()
  def run! do
    Staff.seed!(
      user_id: id(:admin_user),
      email_env: "CLUBEIRA_DEMO_ADMIN_EMAIL",
      email: "admin.demo@clubeira.local",
      password_env: "CLUBEIRA_DEMO_ADMIN_PASSWORD",
      password: "clubeira-admin-local",
      role_key: "admin",
      role_name: "Administração do polo",
      memberships: [
        [
          polo_id: id(:polo_sobral),
          role_id: id(:admin_role_sobral),
          membership_id: id(:admin_membership_sobral)
        ],
        [
          polo_id: id(:polo_londrina),
          role_id: id(:admin_role_londrina),
          membership_id: id(:admin_membership_londrina)
        ]
      ]
    )
  end

  defp id(name), do: Ids.fetch!(name)
end
