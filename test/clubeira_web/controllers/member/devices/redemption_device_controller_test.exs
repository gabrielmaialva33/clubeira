defmodule ClubeiraWeb.Member.RedemptionDeviceControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Devices.DeviceInstallation
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  @password "uma-senha-de-teste-forte"

  test "an authenticated member enrolls an installation once and can redeem with it", %{
    conn: conn
  } do
    fixture =
      RedemptionsFixtures.create!(
        device_policy: "authorized_devices",
        authorize_device: false
      )

    installation_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    bearer_token = authenticate!(fixture.ids.user)

    attributes = %{
      "access_contract_id" => fixture.ids.access_contract,
      "installation_token" => installation_token,
      "platform" => "web"
    }

    created =
      conn
      |> put_req_header("authorization", "Bearer #{bearer_token}")
      |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-devices", attributes)

    assert %{
             "data" => %{
               "id" => device_id,
               "access_contract_id" => access_contract_id,
               "platform" => "web",
               "status" => "active",
               "authorized_at" => authorized_at
             }
           } = json_response(created, 201)

    assert access_contract_id == fixture.ids.access_contract
    assert {:ok, _authorized_at, 0} = DateTime.from_iso8601(authorized_at)
    refute created.resp_body =~ installation_token

    replayed =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{bearer_token}")
      |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-devices", attributes)

    assert %{"data" => %{"id" => ^device_id}} = json_response(replayed, 200)

    assert %{rows: [[1, 1, 1, 1, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM user_device_authorizations
                  WHERE user_id = $1 AND device_installation_id = $2),
                 (SELECT count(*) FROM contract_redemption_devices
                  WHERE access_contract_id = $3 AND device_installation_id = $2),
                 (SELECT count(*) FROM tenant_audit_events
                  WHERE action = 'redemption_device.authorized' AND resource_id = (
                    SELECT id FROM contract_redemption_devices
                    WHERE access_contract_id = $3 AND device_installation_id = $2
                  )),
                 (SELECT count(*) FROM domain_events
                  WHERE event_type = 'redemption_device.authorized' AND aggregate_id = (
                    SELECT id FROM contract_redemption_devices
                    WHERE access_contract_id = $3 AND device_installation_id = $2
                  )),
                 (SELECT count(*) FROM outbox_messages AS message
                  JOIN domain_events AS event ON event.id = message.domain_event_id
                  WHERE event.event_type = 'redemption_device.authorized'
                    AND event.aggregate_id = (
                      SELECT id FROM contract_redemption_devices
                      WHERE access_contract_id = $3 AND device_installation_id = $2
                    ))
               """,
               [fixture.ids.user, device_id, fixture.ids.access_contract]
             )

    request =
      RedemptionsFixtures.request(fixture, %{
        device_installation_id: device_id,
        idempotency_key: "enrolled-device-redemption"
      })

    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, request)
    assert redemption.entitlement_allocation_id == fixture.ids.entitlement_allocation
  end

  test "enrollment rejects malformed installation secrets at the HTTP boundary", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    bearer_token = authenticate!(fixture.ids.user)

    assert conn
           |> put_req_header("authorization", "Bearer #{bearer_token}")
           |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-devices", %{
             "access_contract_id" => fixture.ids.access_contract,
             "installation_token" => Base.url_encode64("predictable", padding: false),
             "platform" => "desktop"
           })
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }
  end

  test "an account cannot enroll a device in another member's contract", %{conn: conn} do
    owner = RedemptionsFixtures.create!()
    other_member = RedemptionsFixtures.create!()
    bearer_token = authenticate!(other_member.ids.user)

    assert conn
           |> put_req_header("authorization", "Bearer #{bearer_token}")
           |> post("/api/v1/polos/#{owner.polo_slug}/me/redemption-devices", %{
             "access_contract_id" => owner.ids.access_contract,
             "installation_token" => random_installation_token(),
             "platform" => "ios"
           })
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "the frozen polo policy caps devices and rolls back a rejected installation", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(authorize_device: false)
    bearer_token = authenticate!(fixture.ids.user)
    initial_device_count = Repo.aggregate(DeviceInstallation, :count)

    for _index <- 1..3 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{bearer_token}")
             |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-devices", %{
               "access_contract_id" => fixture.ids.access_contract,
               "installation_token" => random_installation_token(),
               "platform" => "android"
             })
             |> json_response(201)
    end

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{bearer_token}")
           |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-devices", %{
             "access_contract_id" => fixture.ids.access_contract,
             "installation_token" => random_installation_token(),
             "platform" => "android"
           })
           |> json_response(409) == %{"errors" => %{"detail" => "Conflict"}}

    assert Repo.aggregate(DeviceInstallation, :count) == initial_device_count + 3
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp random_installation_token do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end
end
