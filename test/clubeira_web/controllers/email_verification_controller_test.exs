defmodule ClubeiraWeb.EmailVerificationControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias Clubeira.Accounts.EmailVerificationToken
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.SystemEvent
  alias Clubeira.LegalFixtures
  alias Clubeira.Mailer
  alias Clubeira.Repo

  @password "uma-senha-forte-para-verificar-email"

  setup :set_swoosh_global

  test "registration issues a hashed verification token and sends the raw token by email", %{
    conn: conn
  } do
    {registration_conn, session, token} = register!(conn, "  NOVO@Example.Test ")

    assert session["user"]["email"] == "novo@example.test"
    assert session["user"]["email_verified_at"] == nil
    assert get_resp_header(registration_conn, "cache-control") == ["private, no-store"]

    decoded_token = Base.url_decode64!(token, padding: false)

    assert %{rows: [[token_hash, expires_at, nil, nil]]} =
             Repo.query!(
               """
               SELECT token_hash, expires_at, consumed_at, revoked_at
               FROM user_email_verification_tokens
               WHERE user_id = $1
               """,
               [Ecto.UUID.dump!(session["user"]["id"])]
             )

    assert token_hash == :crypto.hash(:sha256, decoded_token)
    assert DateTime.after?(expires_at, DateTime.utc_now())
    refute token_hash == token
  end

  test "verification is atomic, auditable, and idempotent for the same token", %{conn: conn} do
    {_registration_conn, session, token} = register!(conn, "verify@example.test")
    user_id = session["user"]["id"]

    verification_conn =
      conn
      |> recycle()
      |> post(~p"/api/v1/auth/email-verifications", %{"token" => token})

    assert response(verification_conn, :no_content) == ""
    assert get_resp_header(verification_conn, "cache-control") == ["private, no-store"]

    user = Repo.get!(User, user_id)
    assert %DateTime{} = user.email_verified_at

    assert %{rows: [[consumed_at, nil]]} =
             Repo.query!(
               """
               SELECT consumed_at, revoked_at
               FROM user_email_verification_tokens
               WHERE user_id = $1
               """,
               [Ecto.UUID.dump!(user_id)]
             )

    assert %DateTime{} = consumed_at

    assert %SystemEvent{
             actor_user_id: ^user_id,
             action: "account.email_verified",
             resource_type: "user",
             resource_id: ^user_id
           } = Repo.get_by!(SystemEvent, request_id: verification_conn.assigns.request_id)

    assert verification_conn
           |> recycle()
           |> post(~p"/api/v1/auth/email-verifications", %{"token" => token})
           |> response(:no_content) == ""

    assert Repo.aggregate(
             from(event in SystemEvent,
               where: event.action == "account.email_verified" and event.resource_id == ^user_id
             ),
             :count
           ) == 1

    assert %{"data" => %{"user" => %{"email_verified_at" => verified_at}}} =
             conn
             |> recycle()
             |> post(~p"/api/v1/auth/sessions", %{
               "email" => user.email,
               "password" => @password
             })
             |> json_response(201)

    assert {:ok, _verified_at, 0} = DateTime.from_iso8601(verified_at)
  end

  test "an authenticated resend revokes the previous token and verified users are a no-op", %{
    conn: conn
  } do
    {_registration_conn, session, first_token} = register!(conn, "resend@example.test")
    access_token = session["access_token"]

    request_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> post(~p"/api/v1/auth/email-verification-requests")

    assert response(request_conn, :accepted) == ""
    second_token = receive_verification_token()
    refute first_token == second_token

    assert request_conn
           |> recycle()
           |> post(~p"/api/v1/auth/email-verifications", %{"token" => first_token})
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert request_conn
           |> recycle()
           |> post(~p"/api/v1/auth/email-verifications", %{"token" => second_token})
           |> response(:no_content) == ""

    assert request_conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{access_token}")
           |> post(~p"/api/v1/auth/email-verification-requests")
           |> response(:accepted) == ""

    refute_email_sent()
    assert Repo.aggregate("user_email_verification_tokens", :count) == 2
  end

  test "expired and malformed credentials never verify the account", %{conn: conn} do
    {_registration_conn, session, token} = register!(conn, "expired@example.test")
    user_id = session["user"]["id"]
    now = DateTime.utc_now(:microsecond)

    Repo.update_all("user_email_verification_tokens",
      set: [inserted_at: DateTime.add(now, -86_400), expires_at: DateTime.add(now, -1)]
    )

    for candidate <- [token, "not-a-token"] do
      assert conn
             |> recycle()
             |> post(~p"/api/v1/auth/email-verifications", %{"token" => candidate})
             |> json_response(422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end

    assert Repo.get!(User, user_id).email_verified_at == nil
  end

  test "resend requires an authenticated account and malformed confirmation stays generic", %{
    conn: conn
  } do
    assert conn
           |> post(~p"/api/v1/auth/email-verification-requests")
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}

    assert conn
           |> recycle()
           |> post(~p"/api/v1/auth/email-verifications", %{})
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }
  end

  test "delivery failure preserves registration, revokes the credential, and emits telemetry", %{
    conn: conn
  } do
    previous_mailer_config = Application.fetch_env!(:clubeira, Mailer)
    Application.put_env(:clubeira, Mailer, adapter: Clubeira.FailingMailerAdapter)

    on_exit(fn -> Application.put_env(:clubeira, Mailer, previous_mailer_config) end)

    handler_id = {__MODULE__, make_ref()}
    test_process = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:clubeira, :accounts, :email_verification_delivery_failed],
        fn event, measurements, metadata, _config ->
          send(test_process, {:delivery_failed, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    terms = LegalFixtures.registration_terms!()

    {registration_conn, log} =
      with_log(fn ->
        post(conn, ~p"/api/v1/auth/registrations", %{
          "email" => "verification-delivery-failure@example.test",
          "password" => @password,
          "legal_document_version_ids" => [terms.version_id]
        })
      end)

    assert %{"data" => %{"user" => %{"id" => user_id}}} =
             json_response(registration_conn, 201)

    assert log =~ "email verification delivery failed token_id="
    refute_email_sent()

    verification = Repo.get_by!(EmailVerificationToken, user_id: user_id)
    assert %DateTime{} = verification.revoked_at

    assert_receive {:delivery_failed, [:clubeira, :accounts, :email_verification_delivery_failed],
                    %{count: 1}, %{email_verification_token_id: verification_id}}

    assert verification_id == verification.id
  end

  defp register!(conn, email) do
    terms = LegalFixtures.registration_terms!()

    registration_conn =
      conn
      |> recycle()
      |> post(~p"/api/v1/auth/registrations", %{
        "email" => email,
        "password" => @password,
        "legal_document_version_ids" => [terms.version_id]
      })

    assert %{"data" => session} = json_response(registration_conn, 201)
    {registration_conn, session, receive_verification_token()}
  end

  defp receive_verification_token do
    assert_email_sent(fn email ->
      assert email.subject == "Confirme seu e-mail do Clubeira"
      assert [_, token] = Regex.run(~r/[?&]token=([A-Za-z0-9_-]{43})/, email.text_body)
      send(self(), {:email_verification_token, token})
      true
    end)

    assert_receive {:email_verification_token, token}
    token
  end
end
