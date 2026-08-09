defmodule Clubeira.PrivacyFixtures do
  @moduledoc false

  alias Clubeira.Factory
  alias Clubeira.Repo

  @spec consent_purpose!() :: map()
  def consent_purpose! do
    document_id = uuid7()
    version_id = uuid7()
    purpose_id = uuid7()
    now = DateTime.utc_now(:microsecond)
    code = "personalization-#{purpose_id}"
    name = "Personalização da experiência"

    {1, nil} =
      Repo.insert_all("legal_documents", [
        %{
          id: Ecto.UUID.dump!(document_id),
          code: "consent-notice-#{document_id}",
          document_kind: "consent_notice",
          audience: "consumer",
          status: "active",
          inserted_at: now,
          updated_at: now
        }
      ])

    {1, nil} =
      Repo.insert_all("legal_document_versions", [
        %{
          id: Ecto.UUID.dump!(version_id),
          legal_document_id: Ecto.UUID.dump!(document_id),
          version: 1,
          locale: "pt-BR",
          content_uri: "/legal/test-consent-notice.txt",
          content_sha256: :crypto.hash(:sha256, "test consent notice"),
          effective_during: Factory.tstz_range(DateTime.add(now, -60)),
          published_at: DateTime.add(now, -60),
          inserted_at: now
        }
      ])

    {1, nil} =
      Repo.insert_all("processing_purposes", [
        %{
          id: Ecto.UUID.dump!(purpose_id),
          code: code,
          name: name,
          legal_basis: "consent",
          legal_document_version_id: Ecto.UUID.dump!(version_id),
          status: "active",
          inserted_at: now,
          updated_at: now
        }
      ])

    %{
      document_id: document_id,
      version_id: version_id,
      purpose_id: purpose_id,
      code: code,
      name: name
    }
  end

  @spec privacy_officer!(Clubeira.Accounts.User.t()) :: map()
  def privacy_officer!(user) do
    now = DateTime.utc_now(:microsecond)

    organization =
      Factory.insert(:organization,
        kind: "platform",
        legal_name: "Clubeira Plataforma",
        trade_name: "Clubeira",
        status: "active"
      )

    role =
      Factory.insert(:organization_role,
        organization_id: organization.id,
        key: "privacy_officer",
        name: "Encarregado de privacidade",
        status: "active"
      )

    membership =
      Factory.insert(:organization_membership,
        organization_id: organization.id,
        user_id: user.id,
        valid_during: Factory.tstz_range(DateTime.add(now, -60)),
        status: "active"
      )

    membership_role =
      Factory.insert(:organization_membership_role,
        organization_id: organization.id,
        organization_membership_id: membership.id,
        organization_role_id: role.id,
        inserted_at: now
      )

    %{
      organization: organization,
      role: role,
      membership: membership,
      membership_role: membership_role
    }
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
