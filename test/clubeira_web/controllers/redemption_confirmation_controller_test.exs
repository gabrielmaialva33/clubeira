defmodule ClubeiraWeb.RedemptionConfirmationControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.User
  alias Clubeira.Redemptions
  alias Clubeira.Redemptions.Grant
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  @password "uma-senha-de-teste-forte"
  @validation_secret Base.url_encode64(
                       :crypto.hash(:sha256, "validation-secret-for-controller-test"),
                       padding: false
                     )

  test "member grant and validation credential confirm one redemption end to end", %{conn: conn} do
    fixture =
      RedemptionsFixtures.create!(
        device_policy: "authorized_devices",
        authorize_device: false,
        validation_credential_secret: @validation_secret
      )

    account_token = authenticate!(fixture.ids.user)
    installation_token = random_token()

    enrollment =
      conn
      |> put_req_header("authorization", "Bearer #{account_token}")
      |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-devices", %{
        "access_contract_id" => fixture.ids.access_contract,
        "installation_token" => installation_token,
        "platform" => "android"
      })
      |> json_response(201)

    assert %{"data" => %{"id" => device_id}} = enrollment

    grant_response =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{account_token}")
      |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-grants", %{
        "entitlement_allocation_id" => fixture.ids.entitlement_allocation,
        "installation_token" => installation_token
      })
      |> json_response(201)

    assert %{
             "data" => %{
               "grant" => grant,
               "expires_at" => expires_at
             }
           } = grant_response

    assert is_binary(grant)
    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(expires_at)
    refute inspect(grant_response) =~ device_id

    confirmation =
      conn
      |> recycle()
      |> put_req_header("authorization", "Validation #{@validation_secret}")
      |> put_req_header("idempotency-key", "merchant-confirmation-001")
      |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})

    assert %{
             "data" => %{
               "id" => redemption_id,
               "entitlement_allocation_id" => allocation_id,
               "validation_point_id" => validation_point_id,
               "units" => 1,
               "redeemed_at" => redeemed_at
             }
           } = json_response(confirmation, 201)

    assert allocation_id == fixture.ids.entitlement_allocation
    assert validation_point_id == fixture.ids.validation_point
    assert {:ok, _redeemed_at, 0} = DateTime.from_iso8601(redeemed_at)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Validation #{@validation_secret}")
           |> put_req_header("idempotency-key", "merchant-confirmation-001")
           |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})
           |> json_response(201) == json_response(confirmation, 201)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Validation #{@validation_secret}")
           |> put_req_header("idempotency-key", "merchant-confirmation-002")
           |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})
           |> json_response(409) == %{"errors" => %{"detail" => "Conflict"}}

    assert %{rows: [[^redemption_id, 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT redemption.id::text, allocation.available_units
               FROM redemptions AS redemption
               JOIN entitlement_allocations AS allocation
                 ON allocation.id = redemption.entitlement_allocation_id
                AND allocation.polo_id = redemption.polo_id
               WHERE redemption.id = $1
               """,
               [redemption_id]
             )
  end

  test "tampered grants and unknown validation credentials cannot consume entitlement", %{
    conn: conn
  } do
    fixture =
      RedemptionsFixtures.create!(
        device_policy: "authorized_devices",
        authorize_device: false,
        validation_credential_secret: @validation_secret
      )

    account_token = authenticate!(fixture.ids.user)
    installation_token = random_token()

    assert conn
           |> put_req_header("authorization", "Bearer #{account_token}")
           |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-devices", %{
             "access_contract_id" => fixture.ids.access_contract,
             "installation_token" => installation_token,
             "platform" => "ios"
           })
           |> json_response(201)

    assert %{"data" => %{"grant" => grant}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{account_token}")
             |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-grants", %{
               "entitlement_allocation_id" => fixture.ids.entitlement_allocation,
               "installation_token" => installation_token
             })
             |> json_response(201)

    tampered_grant = "x" <> binary_part(grant, 1, byte_size(grant) - 1)

    for {credential, presented_grant, idempotency_key} <- [
          {@validation_secret, tampered_grant, "tampered-grant-001"},
          {random_token(), grant, "unknown-credential-001"}
        ] do
      denied =
        conn
        |> recycle()
        |> put_req_header("authorization", "Validation #{credential}")
        |> put_req_header("idempotency-key", idempotency_key)
        |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{
          "grant" => presented_grant
        })

      assert json_response(denied, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
      assert get_resp_header(denied, "www-authenticate") != []
    end

    assert %{rows: [[1, 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT allocation.available_units, count(redemption.id)
               FROM entitlement_allocations AS allocation
               LEFT JOIN redemptions AS redemption
                 ON redemption.entitlement_allocation_id = allocation.id
                AND redemption.polo_id = allocation.polo_id
               WHERE allocation.id = $1
               GROUP BY allocation.available_units
               """,
               [fixture.ids.entitlement_allocation]
             )
  end

  test "a validation credential is authenticated only inside its own polo" do
    sobral = RedemptionsFixtures.create!()
    londrina_secret = random_token()

    _londrina =
      RedemptionsFixtures.create!(validation_credential_secret: londrina_secret)

    grant =
      Grant.issue(
        sobral.scope,
        sobral.ids.entitlement_allocation,
        sobral.ids.device,
        DateTime.utc_now(:microsecond)
      )

    assert {:error, :validation_credential_invalid} =
             Clubeira.TestDatabaseRole.as_owner(fn ->
               Redemptions.confirm_grant(
                 sobral.polo_slug,
                 %{
                   grant: grant.token,
                   validation_credential: londrina_secret,
                   idempotency_key: "cross-polo-validation-credential"
                 },
                 RequestContext.new!()
               )
             end)
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp random_token do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end
end
