defmodule ClubeiraWeb.PartnerAuthTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Directory
  alias Clubeira.Directory.OrganizationMembership
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias ClubeiraWeb.PartnerAuth

  @password "uma-senha-forte-para-o-portal-parceiro"

  test "authorizes only current partner places and returns tenant navigation hints" do
    fixture = RedemptionsFixtures.create!()
    %{user: user} = grant_partner!(fixture)
    account_scope = account_scope!(user)

    assert {:ok, %{polos: [polo]}} = PartnerAuth.authorize(account_scope)
    assert polo.id == fixture.ids.polo
    assert polo.slug == fixture.polo_slug
    assert polo.capabilities == [:manage_own_places]
  end

  test "ordinary and tenant-only users do not gain the partner surface" do
    ordinary = Factory.insert(:user)
    assert {:error, :forbidden} = ordinary |> account_scope!() |> PartnerAuth.authorize()

    fixture = RedemptionsFixtures.create!()
    tenant_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    tenant_user = Repo.get!(Clubeira.Accounts.User, tenant_scope.actor_user_id)

    assert {:error, :forbidden} = tenant_user |> account_scope!() |> PartnerAuth.authorize()
  end

  test "global affiliation revocation removes partner browser access immediately" do
    fixture = RedemptionsFixtures.create!()
    %{user: user} = grant_partner!(fixture)
    account_scope = account_scope!(user)

    membership = Repo.get_by!(OrganizationMembership, user_id: user.id)

    membership
    |> Ecto.Changeset.change(status: "revoked")
    |> Repo.update!()

    assert {:error, :forbidden} = PartnerAuth.authorize(account_scope)
  end

  defp grant_partner!(fixture) do
    admin = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    user = Factory.insert(:user, email_verified_at: DateTime.utc_now(:microsecond))
    organization = Factory.insert(:organization, trade_name: "Parceiro Browser")

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.ids.place),
      organization: organization
    )

    assert {:ok, access} =
             Directory.grant_partner_access(admin, fixture.ids.place, %{
               "email" => user.email,
               "idempotency_key" => "partner-browser-access-#{uuid7()}"
             })

    # The SQL sandbox keeps one outer transaction timestamp. Move the newly
    # granted range behind it so actor-bootstrap reads model the next request.
    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE polo_memberships
      SET valid_during = tstzrange(statement_timestamp() - interval '1 minute', NULL, '[)')
      WHERE id = $1
      """,
      [access["id"]]
    )

    %{access: access, organization: organization, user: user}
  end

  defp account_scope!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    account_scope
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
