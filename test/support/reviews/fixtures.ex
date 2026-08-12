defmodule Clubeira.ReviewsFixtures do
  @moduledoc false

  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope

  @spec pending_review!() :: map()
  def pending_review! do
    fixture = RedemptionsFixtures.create!()
    {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)

    {:ok, submission} =
      Reviews.submit_verified(fixture.scope, %{
        place_id: fixture.ids.place,
        source_redemption_id: redemption.id,
        rating: 5,
        title: "Experiência verificada",
        body: "O benefício foi entregue como anunciado.",
        idempotency_key: "review-fixture-#{uuid7()}"
      })

    Map.merge(fixture, %{redemption: redemption, submission: submission})
  end

  @spec grant_moderator!(map(), keyword()) :: Scope.t()
  def grant_moderator!(fixture, options \\ []) do
    user_id = Keyword.get_lazy(options, :user_id, &uuid7/0)
    role_key = Keyword.get(options, :role_key, "review_moderator")
    role_id = uuid7()
    membership_id = uuid7()
    suffix = String.slice(String.replace(user_id, "-", ""), -12, 12)

    if Keyword.get(options, :insert_user, true) do
      RedemptionsFixtures.insert_user!(user_id, "moderator-#{suffix}@example.test")
    end

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      INSERT INTO polo_roles (id, polo_id, key, name, status)
      VALUES ($1, $2, $3, 'Moderação de avaliações', 'active')
      """,
      [role_id, fixture.ids.polo, role_key]
    )

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      INSERT INTO polo_memberships (id, polo_id, user_id, valid_during, status)
      VALUES (
        $1,
        $2,
        $3,
        tstzrange(statement_timestamp() - interval '1 hour', NULL, '[)'),
        'active'
      )
      """,
      [membership_id, fixture.ids.polo, user_id]
    )

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      INSERT INTO polo_membership_roles (polo_id, polo_membership_id, polo_role_id)
      VALUES ($1, $2, $3)
      """,
      [fixture.ids.polo, membership_id, role_id]
    )

    Scope.new!(fixture.ids.polo, actor_user_id: user_id, request_id: uuid7())
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
