defmodule ClubeiraWeb.PartnerBrowserFixtures do
  @moduledoc false

  alias Clubeira.Accounts
  alias Clubeira.Directory
  alias Clubeira.Directory.OrganizationMembership
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-o-portal-parceiro"

  def grant_partner!(fixture, options \\ []) do
    admin =
      Keyword.get_lazy(options, :admin, fn ->
        ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
      end)

    user =
      Keyword.get_lazy(options, :user, fn ->
        Factory.insert(:user, email_verified_at: now())
      end)

    organization =
      Keyword.get_lazy(options, :organization, fn ->
        Factory.insert(:organization, trade_name: "Parceiro Browser")
      end)

    place_id = Keyword.get(options, :place_id, fixture.ids.place)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, place_id),
      organization: organization
    )

    {:ok, access} =
      Directory.grant_partner_access(admin, place_id, %{
        "email" => user.email,
        "idempotency_key" => "partner-browser-access-#{uuid7()}"
      })

    # The SQL sandbox keeps one outer transaction timestamp. Move the newly
    # granted tenant range behind it so actor-bootstrap models the next request.
    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE polo_memberships
      SET valid_during = tstzrange(statement_timestamp() - interval '1 minute', NULL, '[)')
      WHERE id = $1
      """,
      [access["id"]]
    )

    organization_membership =
      Repo.get_by!(OrganizationMembership,
        organization_id: organization.id,
        user_id: user.id
      )

    %{
      access: access,
      admin: admin,
      organization: organization,
      organization_membership: organization_membership,
      user: user
    }
  end

  def authenticate!(user) do
    {:ok, _credential} = Accounts.set_password(user, @password)
    {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  def assign_additional_place!(_fixture, partner, place_id) do
    place = Repo.get!(Place, place_id)

    Factory.insert(:place_operator,
      place: place,
      organization: partner.organization
    )

    role =
      Factory.insert(:place_staff_role,
        place: place,
        key: "manager",
        name: "Gestor"
      )

    assignment =
      Factory.insert(:place_staff_assignment,
        place: place,
        organization: partner.organization,
        user: partner.user,
        organization_membership: partner.organization_membership
      )

    Factory.insert(:place_staff_assignment_role,
      place_id: place.id,
      place_staff_assignment_id: assignment.id,
      place_staff_role_id: role.id
    )

    assignment
  end

  def published_review! do
    fixture = ReviewsFixtures.pending_review!()
    moderator = ReviewsFixtures.grant_moderator!(fixture)

    {:ok, _review} =
      Reviews.moderate(moderator, %{
        review_id: fixture.submission.review.id,
        action: "publish",
        reason: "Avaliação adequada para o portal parceiro.",
        idempotency_key: "partner-browser-review-publish-#{uuid7()}"
      })

    fixture
  end

  def revoke_organization_membership!(membership) do
    membership
    |> Ecto.Changeset.change(status: "revoked")
    |> Repo.update!()
  end

  defp now, do: DateTime.utc_now(:microsecond)
  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
