defmodule ClubeiraWeb.MemberApiTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.SystemEvent
  alias Clubeira.RedemptionsFixtures

  @password "uma-senha-de-teste-forte"

  test "login, multi-polo subscriptions, wallet, and logout form one authenticated flow", %{
    conn: conn
  } do
    first = RedemptionsFixtures.create!()

    second =
      RedemptionsFixtures.create!(
        user_id: first.ids.user,
        insert_user: false,
        allocation_kind: "shared_scope"
      )

    user = Clubeira.Repo.get!(User, first.ids.user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    untrusted_request_id = Ecto.UUID.generate(version: 7)

    login_conn =
      conn
      |> put_req_header("x-request-id", untrusted_request_id)
      |> post(~p"/api/v1/auth/sessions", %{
        "email" => user.email,
        "password" => @password
      })

    assert %{
             "data" => %{
               "access_token" => token,
               "token_type" => "Bearer",
               "expires_at" => expires_at,
               "user" => %{"id" => user_id, "email" => email}
             }
           } = json_response(login_conn, 201)

    assert user_id == user.id
    assert email == user.email
    assert is_binary(token)
    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(expires_at)
    assert [request_id] = get_resp_header(login_conn, "x-request-id")
    assert {:ok, ^request_id} = Ecto.UUID.cast(request_id)
    refute request_id == untrusted_request_id

    assert %SystemEvent{actor_user_id: actor_user_id, request_id: audit_request_id} =
             Clubeira.Repo.get_by!(SystemEvent,
               action: "authentication.session.created",
               request_id: request_id
             )

    assert actor_user_id == user.id
    assert audit_request_id == request_id

    subscriptions_conn =
      conn
      |> bearer(token)
      |> get(~p"/api/v1/me/subscriptions")

    assert %{"data" => subscriptions, "meta" => %{"count" => 2}} =
             json_response(subscriptions_conn, 200)

    assert MapSet.new(Enum.map(subscriptions, &get_in(&1, ["polo", "id"]))) ==
             MapSet.new([first.ids.polo, second.ids.polo])

    assert Enum.all?(subscriptions, fn subscription ->
             subscription["status"] == "active" and
               subscription["current_cycle"]["status"] == "active"
           end)

    first_wallet =
      conn
      |> bearer(token)
      |> get(~p"/api/v1/polos/#{first.polo_slug}/me/vouchers")
      |> json_response(200)

    assert %{
             "data" => %{
               "polo" => %{"id" => first_polo_id},
               "vouchers" => [first_voucher]
             },
             "meta" => %{"count" => 1}
           } = first_wallet

    assert first_polo_id == first.ids.polo
    assert first_voucher["allocation_id"] == first.ids.entitlement_allocation
    assert first_voucher["allocation_kind"] == "per_place"
    assert first_voucher["available_units"] == 1
    assert [%{"polo_place_id" => first_place_id}] = first_voucher["places"]
    assert first_place_id == first.ids.polo_place

    second_wallet =
      conn
      |> bearer(token)
      |> get(~p"/api/v1/polos/#{second.polo_slug}/me/vouchers")
      |> json_response(200)

    assert %{"data" => %{"vouchers" => [second_voucher]}} = second_wallet
    assert second_voucher["allocation_id"] == second.ids.entitlement_allocation
    assert second_voucher["allocation_kind"] == "shared_scope"
    assert [%{"polo_place_id" => second_place_id}] = second_voucher["places"]
    assert second_place_id == second.ids.polo_place

    logout_conn =
      conn
      |> bearer(token)
      |> delete(~p"/api/v1/auth/session")

    assert response(logout_conn, 204) == ""

    assert conn
           |> bearer(token)
           |> get(~p"/api/v1/me/subscriptions")
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}
  end

  test "authentication failures are generic and protected endpoints require one bearer token", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    user = Clubeira.Repo.get!(User, fixture.ids.user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)

    assert conn
           |> post(~p"/api/v1/auth/sessions", %{
             "email" => user.email,
             "password" => "senha-totalmente-errada"
           })
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}

    assert conn
           |> recycle()
           |> post(~p"/api/v1/auth/sessions", %{"email" => user.email})
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    unauthorized = get(conn, ~p"/api/v1/me/subscriptions")
    assert json_response(unauthorized, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    assert [challenge] = get_resp_header(unauthorized, "www-authenticate")
    assert challenge =~ "Bearer"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Basic sem-token")
           |> get(~p"/api/v1/me/subscriptions")
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}
  end

  test "subscriptions paginate actor routes with an opaque cursor", %{conn: conn} do
    first = RedemptionsFixtures.create!()

    second =
      RedemptionsFixtures.create!(
        user_id: first.ids.user,
        insert_user: false
      )

    user = Clubeira.Repo.get!(User, first.ids.user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    first_page =
      conn
      |> bearer(session.token)
      |> get(~p"/api/v1/me/subscriptions?limit=1")
      |> json_response(200)

    assert %{
             "data" => [_first_subscription],
             "meta" => %{
               "count" => 1,
               "page" => %{
                 "limit" => 1,
                 "has_more" => true,
                 "next_cursor" => cursor
               }
             }
           } = first_page

    second_page =
      conn
      |> recycle()
      |> bearer(session.token)
      |> get(~p"/api/v1/me/subscriptions?limit=1&after=#{cursor}")
      |> json_response(200)

    assert %{
             "data" => [_second_subscription],
             "meta" => %{
               "count" => 1,
               "page" => %{
                 "limit" => 1,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           } = second_page

    returned_polo_ids =
      [first_page, second_page]
      |> Enum.flat_map(& &1["data"])
      |> Enum.map(&get_in(&1, ["polo", "id"]))
      |> MapSet.new()

    assert returned_polo_ids == MapSet.new([first.ids.polo, second.ids.polo])

    assert conn
           |> recycle()
           |> bearer(session.token)
           |> get(~p"/api/v1/me/subscriptions?limit=0")
           |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}

    assert conn
           |> recycle()
           |> bearer(session.token)
           |> get(~p"/api/v1/me/subscriptions?after=invalid")
           |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
  end

  test "an account without contracts receives an empty subscription page", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    assert conn
           |> bearer(session.token)
           |> get(~p"/api/v1/me/subscriptions")
           |> json_response(200) == %{
             "data" => [],
             "meta" => %{
               "count" => 0,
               "page" => %{
                 "limit" => 20,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           }
  end

  test "wallet returns not found for an unknown polo route", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    user = Clubeira.Repo.get!(User, fixture.ids.user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    assert conn
           |> bearer(session.token)
           |> get(~p"/api/v1/polos/unknown-polo/me/vouchers")
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "an authenticated member cannot see another member's vouchers", %{conn: conn} do
    member = RedemptionsFixtures.create!()
    another_member = RedemptionsFixtures.create!()
    user = Clubeira.Repo.get!(User, member.ids.user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    response =
      conn
      |> bearer(session.token)
      |> get(~p"/api/v1/polos/#{another_member.polo_slug}/me/vouchers")
      |> json_response(200)

    assert %{"data" => %{"vouchers" => []}, "meta" => %{"count" => 0}} = response
    refute inspect(response) =~ another_member.ids.entitlement_allocation
  end

  test "wallet applies the canonical contract lifecycle rules" do
    fixture = RedemptionsFixtures.create!()
    user = Clubeira.Repo.get!(User, fixture.ids.user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(session.token)

    assert {:ok, %{vouchers: [_voucher]}} =
             Clubeira.Subscriptions.list_wallet(scope, fixture.polo_slug)

    now = DateTime.utc_now(:microsecond)

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE access_contracts
      SET status = 'past_due'
      WHERE id = $1
      """,
      [fixture.ids.access_contract]
    )

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE benefit_cycles
      SET delinquency_grace_until = $2
      WHERE id = $1
      """,
      [fixture.ids.benefit_cycle, DateTime.add(now, -1, :second)]
    )

    assert {:ok, %{vouchers: []}} =
             Clubeira.Subscriptions.list_wallet(scope, fixture.polo_slug)

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE benefit_cycles
      SET delinquency_grace_until = $2
      WHERE id = $1
      """,
      [fixture.ids.benefit_cycle, DateTime.add(now, 60, :second)]
    )

    assert {:ok, %{vouchers: [_voucher]}} =
             Clubeira.Subscriptions.list_wallet(scope, fixture.polo_slug)

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE access_contracts
      SET status = 'active', ends_at = $2
      WHERE id = $1
      """,
      [fixture.ids.access_contract, DateTime.add(now, -1, :second)]
    )

    assert {:ok, %{vouchers: []}} =
             Clubeira.Subscriptions.list_wallet(scope, fixture.polo_slug)
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
