defmodule Clubeira.Seeds.Demo.Platform do
  @moduledoc false

  alias Clubeira.Accounts.User
  alias Clubeira.Factory
  alias Clubeira.People
  alias Clubeira.PlatformBilling
  alias Clubeira.Privacy
  alias Clubeira.Repo
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Writer
  alias Clubeira.Tenancy.ActorScope

  @range_start ~U[2026-01-01 00:00:00Z]

  @spec run!(map()) :: map()
  def run!(legal) do
    administrator = Repo.get!(User, id(:admin_user))
    member = Repo.get!(User, id(:member_user))

    seed_platform_access!(administrator)
    plan = publish_plan!(administrator)
    purpose = put_processing_purpose!(administrator, legal.consent.version.id)
    request = seed_member_privacy!(member)

    %{plan: plan, processing_purpose: purpose, privacy_request: request}
  end

  defp seed_platform_access!(administrator) do
    organization =
      Writer.upsert!(
        :organization,
        %{
          id: id(:platform_organization),
          kind: "platform",
          legal_name: "Clubeira Tecnologia Ltda.",
          trade_name: "Clubeira Plataforma",
          country_code: "BR",
          status: "active"
        },
        ~w(kind legal_name trade_name country_code status updated_at)a
      )

    role =
      Writer.upsert!(
        :organization_role,
        %{
          id: id(:platform_admin_role),
          organization_id: organization.id,
          key: "platform_admin",
          name: "Administração da plataforma",
          status: "active"
        },
        ~w(organization_id key name status updated_at)a
      )

    membership =
      Writer.upsert!(
        :organization_membership,
        %{
          id: id(:platform_admin_membership),
          organization_id: organization.id,
          user_id: administrator.id,
          valid_during: Factory.tstz_range(@range_start),
          status: "active"
        },
        ~w(organization_id user_id valid_during status updated_at)a
      )

    Writer.insert_once!(:organization_membership_role, %{
      organization_id: organization.id,
      organization_membership_id: membership.id,
      organization_role_id: role.id,
      inserted_at: @range_start
    })
  end

  defp publish_plan!(administrator) do
    scope = ActorScope.new!(administrator.id, id(:platform_seed_request))

    {:ok, plan} =
      PlatformBilling.publish_plan(scope, "operacao", 1, %{
        "name" => "Clubeira Operação",
        "version_name" => "Operação 2026",
        "description" => "Plano SaaS mensal para operar um polo Clubeira.",
        "features" => [
          %{
            "key" => "partner_limit",
            "name" => "Limite de parceiros",
            "value_kind" => "integer",
            "integer_value" => 100
          },
          %{
            "key" => "review_moderation",
            "name" => "Moderação de avaliações",
            "value_kind" => "boolean",
            "boolean_value" => true
          }
        ],
        "price" => %{
          "currency" => "BRL",
          "amount" => "299.90",
          "billing_interval_unit" => "month",
          "billing_interval_count" => 1,
          "valid_from" => @range_start,
          "valid_until" => ~U[2030-01-01 00:00:00Z]
        }
      })

    plan
  end

  defp put_processing_purpose!(administrator, legal_document_version_id) do
    scope = ActorScope.new!(administrator.id, id(:platform_seed_request))

    {:ok, purpose} =
      Privacy.put_processing_purpose(scope, "product-communications", %{
        "name" => "Comunicações de produtos e benefícios",
        "legal_basis" => "consent",
        "legal_document_version_id" => legal_document_version_id,
        "status" => "active"
      })

    purpose
  end

  defp seed_member_privacy!(member) do
    profile_scope = ActorScope.new!(member.id, id(:member_profile_seed_request))

    {:ok, _profile} =
      People.put_self_profile(profile_scope, %{
        "display_name" => "Membro Demo Clubeira",
        "birth_date" => "1990-05-15"
      })

    request_scope = ActorScope.new!(member.id, id(:privacy_request_seed_request))

    {:ok, %{request: request}} =
      Privacy.submit_request(request_scope, %{
        "client_request_id" => id(:demo_privacy_request),
        "request_type" => "information"
      })

    request
  end

  defp id(name), do: Ids.fetch!(name)
end
