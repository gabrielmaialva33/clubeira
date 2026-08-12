defmodule Clubeira.Privacy.PlatformRequestReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.People
  alias Clubeira.Privacy
  alias Clubeira.PrivacyFixtures
  alias Clubeira.Tenancy.ActorScope

  setup do
    requester = insert(:user)
    requester_scope = ActorScope.new!(requester.id, uuid7())

    assert {:ok, _profile} =
             People.put_self_profile(requester_scope, %{"display_name" => "Titular LGPD"})

    assert {:ok, %{request: request}} =
             Privacy.submit_request(requester_scope, %{
               "client_request_id" => uuid7(),
               "request_type" => "access"
             })

    officer = insert(:user)
    PrivacyFixtures.privacy_officer!(officer)
    officer_scope = ActorScope.new!(officer.id, uuid7())

    %{officer_scope: officer_scope, request: request}
  end

  test "gets one exact platform privacy request with its timeline", %{
    officer_scope: officer_scope,
    request: request
  } do
    assert {:ok, fetched} = Privacy.get_platform_request(officer_scope, request.id)
    assert fetched == request

    assert Privacy.available_actions(fetched.status) ==
             ~w(start_identity_verification start_processing reject cancel)
  end

  test "exact platform reads fail closed for unauthorized, missing and malformed requests", %{
    officer_scope: officer_scope,
    request: request
  } do
    unauthorized = insert(:user)
    unauthorized_scope = ActorScope.new!(unauthorized.id, uuid7())

    assert {:error, :platform_privacy_officer_required} =
             Privacy.get_platform_request(unauthorized_scope, request.id)

    assert {:error, :privacy_request_not_found} =
             Privacy.get_platform_request(officer_scope, uuid7())

    assert {:error, :privacy_request_not_found} =
             Privacy.get_platform_request(officer_scope, "not-a-uuid")

    assert {:error, :invalid_actor_scope} =
             Privacy.get_platform_request(nil, request.id)
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
