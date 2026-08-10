defmodule ClubeiraWeb.Member.DeviceKeyControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @password "uma-senha-forte-para-chave-do-dispositivo"

  test "an authenticated device owner proves, registers and rotates its Ed25519 key", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!(authorize_device: false)
    token = authenticate!(fixture.ids.user)
    installation_token = random_installation_token()

    assert %{"data" => %{"id" => device_id}} =
             conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-devices", %{
               "access_contract_id" => fixture.ids.access_contract,
               "installation_token" => installation_token,
               "platform" => "ios"
             })
             |> json_response(201)

    first_key = key_attributes(installation_token)

    first =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put("/api/v1/me/devices/#{device_id}/key", first_key.attributes)

    assert %{
             "data" => %{
               "device_installation_id" => ^device_id,
               "thumbprint" => first_thumbprint,
               "attestation" => %{"kind" => "none", "status" => "unverified"},
               "valid_from" => valid_from,
               "valid_until" => nil
             }
           } = json_response(first, 201)

    assert first_thumbprint == first_key.thumbprint
    assert {:ok, _valid_from, 0} = DateTime.from_iso8601(valid_from)
    refute first.resp_body =~ installation_token
    refute first.resp_body =~ first_key.attributes["public_key"]
    refute first.resp_body =~ first_key.attributes["proof"]

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> put("/api/v1/me/devices/#{device_id}/key", first_key.attributes)
           |> json_response(200) == json_response(first, 201)

    second_key = key_attributes(installation_token)

    assert %{
             "data" => %{
               "device_installation_id" => ^device_id,
               "thumbprint" => second_thumbprint,
               "valid_until" => nil
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put("/api/v1/me/devices/#{device_id}/key", second_key.attributes)
             |> json_response(200)

    assert second_thumbprint == second_key.thumbprint
    refute second_thumbprint == first_thumbprint

    assert %{"data" => %{"thumbprint" => ^second_thumbprint}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get("/api/v1/me/devices/#{device_id}/key")
             |> json_response(200)

    actor_scope = ActorScope.new!(fixture.ids.user, fixture.scope.request_id)

    assert {:ok, %{rows: [[2, 1, 1, 2]]}} =
             Repo.transact_as_actor(actor_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    count(*),
                    count(*) FILTER (WHERE revoked_at IS NOT NULL),
                    count(*) FILTER (WHERE upper_inf(valid_during)),
                    (SELECT count(*) FROM system_audit_events
                     WHERE actor_user_id = $2
                       AND action IN ('device_key.registered', 'device_key.rotated'))
                  FROM device_keys
                  WHERE device_installation_id = $1
                  """,
                  [Ecto.UUID.dump!(device_id), Ecto.UUID.dump!(fixture.ids.user)]
                )}
             end)
  end

  test "device-key metadata and writes are actor scoped", %{conn: conn} do
    owner = RedemptionsFixtures.create!(authorize_device: false)
    installation_token = random_installation_token()
    owner_token = authenticate!(owner.ids.user)

    assert %{"data" => %{"id" => device_id}} =
             conn
             |> put_req_header("authorization", "Bearer #{owner_token}")
             |> post("/api/v1/polos/#{owner.polo_slug}/me/redemption-devices", %{
               "access_contract_id" => owner.ids.access_contract,
               "installation_token" => installation_token,
               "platform" => "android"
             })
             |> json_response(201)

    other = RedemptionsFixtures.create!()
    other_token = authenticate!(other.ids.user)
    key = key_attributes(installation_token)

    for {method, path, body} <- [
          {:get, "/api/v1/me/devices/#{device_id}/key", nil},
          {:put, "/api/v1/me/devices/#{device_id}/key", key.attributes}
        ] do
      request =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{other_token}")

      response =
        case method do
          :get -> get(request, path)
          :put -> put(request, path, body)
        end

      assert json_response(response, 404) == %{"errors" => %{"detail" => "Not Found"}}
    end
  end

  defp key_attributes(installation_token) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    encoded_public_key = Base.url_encode64(public_key, padding: false)

    message =
      "clubeira-device-key:v1:" <> installation_token <> ":" <> encoded_public_key

    proof = :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])

    %{
      attributes: %{
        "installation_token" => installation_token,
        "public_key" => encoded_public_key,
        "proof" => Base.url_encode64(proof, padding: false)
      },
      thumbprint:
        :sha256
        |> :crypto.hash(public_key)
        |> Base.url_encode64(padding: false)
    }
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
