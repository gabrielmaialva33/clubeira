defmodule ClubeiraWeb.Auth.RegistrationControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts.User
  alias Clubeira.BillingFixtures
  alias Clubeira.LegalFixtures
  alias Clubeira.Repo

  @password "uma-senha-forte-para-criar-conta"

  test "registration creates a usable bearer session for the member journey", %{conn: conn} do
    fixture = BillingFixtures.create!()
    terms = LegalFixtures.registration_terms!()

    assert %{
             "data" => [
               %{
                 "id" => terms_version_id,
                 "required" => true,
                 "document_kind" => "terms_of_service",
                 "content_uri" => content_uri,
                 "content_sha256" => content_sha256
               }
             ]
           } =
             conn
             |> get(~p"/api/v1/legal/registration?locale=pt-BR")
             |> json_response(200)

    assert terms_version_id == terms.version_id

    legal_content = conn |> get(content_uri) |> response(200)

    assert Base.encode16(:crypto.hash(:sha256, legal_content), case: :lower) == content_sha256

    registration_conn =
      post(conn, ~p"/api/v1/auth/registrations", %{
        "email" => "  MEMBRO.NOVO@Example.Test ",
        "password" => @password,
        "legal_document_version_ids" => [terms_version_id]
      })

    assert %{
             "data" => %{
               "access_token" => token,
               "token_type" => "Bearer",
               "expires_at" => expires_at,
               "user" => %{
                 "id" => user_id,
                 "email" => "membro.novo@example.test"
               }
             }
           } = json_response(registration_conn, 201)

    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(expires_at)
    refute registration_conn.resp_body =~ @password
    assert Repo.get!(User, user_id).status == "active"

    assert %{
             "data" => %{
               "id" => order_id,
               "status" => "awaiting_payment",
               "currency" => "BRL"
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "registration-checkout-#{user_id}")
             |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders", %{
               "product_offering_version_id" => fixture.offering_version.id,
               "offering_price_id" => fixture.price.id,
               "quantity" => 1
             })
             |> json_response(201)

    assert {:ok, ^order_id} = Ecto.UUID.cast(order_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
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

  test "registration rejects invalid and duplicate accounts without returning credentials", %{
    conn: conn
  } do
    terms = LegalFixtures.registration_terms!()

    assert conn
           |> post(~p"/api/v1/auth/registrations", %{
             "email" => "invalid",
             "password" => "short",
             "legal_document_version_ids" => [terms.version_id]
           })
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    attributes = %{
      "email" => "duplicate@example.test",
      "password" => @password,
      "legal_document_version_ids" => [terms.version_id]
    }

    assert conn
           |> recycle()
           |> post(~p"/api/v1/auth/registrations", attributes)
           |> json_response(201)

    assert conn
           |> recycle()
           |> post(~p"/api/v1/auth/registrations", attributes)
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}
  end

  test "registration rejects missing or stale legal acceptance", %{conn: conn} do
    LegalFixtures.registration_terms!()
    base = %{"email" => "legal@example.test", "password" => @password}

    for attributes <- [
          base,
          Map.put(base, "legal_document_version_ids", [Ecto.UUID.generate()])
        ] do
      assert conn
             |> recycle()
             |> post(~p"/api/v1/auth/registrations", attributes)
             |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}
    end
  end

  test "registration fails closed while consumer terms are unavailable", %{conn: conn} do
    assert conn
           |> post(~p"/api/v1/auth/registrations", %{
             "email" => "unavailable@example.test",
             "password" => @password,
             "legal_document_version_ids" => [Ecto.UUID.generate()]
           })
           |> json_response(503) == %{"errors" => %{"detail" => "Service Unavailable"}}
  end
end
