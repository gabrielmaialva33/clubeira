defmodule ClubeiraWeb.AccessBootstrapControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.PrivacyFixtures
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-de-teste-forte"

  test "an authenticated administrator discovers its current polo roles and capabilities", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    user = Repo.get!(User, admin_scope.actor_user_id)

    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{session.token}")
      |> get("/api/v1/me/access")
      |> json_response(200)

    assert %{
             "data" => %{
               "platform" => %{"roles" => [], "capabilities" => []},
               "polos" => [access]
             }
           } = response

    assert access["id"] == fixture.ids.polo
    assert access["slug"] == fixture.polo_slug
    assert access["status"] == "active"
    assert is_binary(access["name"])
    assert is_binary(access["timezone"])
    assert access["roles"] == ["admin"]

    assert access["capabilities"] == [
             "manage_billing",
             "manage_operations",
             "manage_partners",
             "moderate_reviews"
           ]
  end

  test "the bootstrap includes current platform roles without manufacturing tenant access", %{
    conn: conn
  } do
    user = Clubeira.Factory.insert(:user)
    _platform_access = PrivacyFixtures.privacy_officer!(user)

    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    assert conn
           |> put_req_header("authorization", "Bearer #{session.token}")
           |> get("/api/v1/me/access")
           |> json_response(200) == %{
             "data" => %{
               "platform" => %{
                 "roles" => ["privacy_officer"],
                 "capabilities" => ["manage_privacy"]
               },
               "polos" => []
             }
           }
  end

  test "the bootstrap omits revoked memberships and every other actor's tenant access", %{
    conn: conn
  } do
    own = RedemptionsFixtures.create!()
    own_scope = ReviewsFixtures.grant_moderator!(own, role_key: "admin")

    other = RedemptionsFixtures.create!()
    _other_scope = ReviewsFixtures.grant_moderator!(other, role_key: "admin")

    RedemptionsFixtures.scoped_query!(
      own,
      "UPDATE polo_memberships SET status = 'revoked' WHERE user_id = $1",
      [own_scope.actor_user_id]
    )

    user = Repo.get!(User, own_scope.actor_user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{session.token}")
      |> get("/api/v1/me/access")
      |> json_response(200)

    assert response["data"]["polos"] == []
    refute inspect(response) =~ own.ids.polo
    refute inspect(response) =~ other.ids.polo
  end

  test "the access bootstrap requires an authenticated session", %{conn: conn} do
    assert conn
           |> get("/api/v1/me/access")
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}
  end
end
