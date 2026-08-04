defmodule ClubeiraWeb.MemberApiTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
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

    login_conn =
      post(conn, ~p"/api/v1/auth/sessions", %{
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

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
