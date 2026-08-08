defmodule Clubeira.Seeds.Demo.Partner do
  @moduledoc false

  alias Clubeira.Factory
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Demo.Staff
  alias Clubeira.Seeds.Writer

  @range_start ~U[2026-01-01 00:00:00Z]

  @spec run!() :: map()
  def run! do
    staff =
      Staff.seed!(
        user_id: id(:partner_user),
        email_env: "CLUBEIRA_DEMO_PARTNER_EMAIL",
        email: "parceiro.demo@clubeira.local",
        password_env: "CLUBEIRA_DEMO_PARTNER_PASSWORD",
        password: "clubeira-parceiro-local",
        role_key: "partner_manager",
        role_name: "Gestão de parceiro",
        memberships: [
          [
            polo_id: id(:polo_sobral),
            role_id: id(:partner_role_sobral),
            membership_id: id(:partner_membership_sobral)
          ]
        ]
      )

    organization_role =
      Writer.insert_once!(:organization_role, %{
        id: id(:organization_role_local_manager),
        organization_id: id(:organization_local_sobral),
        key: "manager",
        name: "Gestão da organização",
        status: "active"
      })

    organization_membership =
      Writer.insert_once!(:organization_membership, %{
        id: id(:organization_membership_local_partner),
        organization_id: id(:organization_local_sobral),
        user_id: id(:partner_user),
        valid_during: Factory.tstz_range(@range_start),
        status: "active"
      })

    Writer.insert_once!(:organization_membership_role, %{
      organization_id: id(:organization_local_sobral),
      organization_membership_id: organization_membership.id,
      organization_role_id: organization_role.id,
      inserted_at: @range_start
    })

    place_role =
      Writer.insert_once!(:place_staff_role, %{
        id: id(:place_staff_role_local_manager),
        place_id: id(:place_local_sobral),
        key: "manager",
        name: "Gestão do estabelecimento",
        status: "active"
      })

    assignment =
      Writer.insert_once!(:place_staff_assignment, %{
        id: id(:place_staff_assignment_local_partner),
        place_id: id(:place_local_sobral),
        organization_id: id(:organization_local_sobral),
        user_id: id(:partner_user),
        organization_membership_id: organization_membership.id,
        valid_during: Factory.tstz_range(@range_start),
        status: "active"
      })

    Writer.insert_once!(:place_staff_assignment_role, %{
      place_id: id(:place_local_sobral),
      place_staff_assignment_id: assignment.id,
      place_staff_role_id: place_role.id,
      inserted_at: @range_start
    })

    Map.merge(staff, %{
      organization_id: id(:organization_local_sobral),
      place_id: id(:place_local_sobral)
    })
  end

  defp id(name), do: Ids.fetch!(name)
end
