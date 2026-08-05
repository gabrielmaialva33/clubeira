defmodule ClubeiraWeb.BackofficePartnerControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Directory.Address
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.OrganizationIdentifier
  alias Clubeira.Directory.Place
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Factory.Brazil
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-de-administracao-forte"

  test "a polo admin onboards an alphanumeric-CNPJ partner into the public directory", %{
    conn: conn
  } do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "partner-onboarding-api-001")
      |> post("/api/v1/polos/#{fixture.polo_slug}/backoffice/partners", %{
        "organization" => %{
          "legal_name" => "Sabores da Serra Alimentos Ltda.",
          "trade_name" => "Sabores da Serra",
          "cnpj" => "12.ABC.345/01DE-35"
        },
        "place" => %{
          "name" => "Sabores da Serra Centro",
          "slug" => "sabores-da-serra-centro",
          "address" => %{
            "postal_code" => "12.345-678",
            "street" => "Rua das Flores",
            "number" => "120",
            "complement" => "Loja 2",
            "district" => "Centro"
          }
        }
      })
      |> json_response(201)

    assert %{
             "data" => %{
               "organization" => %{
                 "id" => organization_id,
                 "legal_name" => "Sabores da Serra Alimentos Ltda.",
                 "trade_name" => "Sabores da Serra",
                 "status" => "active"
               },
               "place" => %{
                 "id" => place_id,
                 "slug" => "sabores-da-serra-centro",
                 "name" => "Sabores da Serra Centro",
                 "status" => "active"
               },
               "participation" => %{
                 "id" => polo_place_id,
                 "status" => "active"
               }
             }
           } = response

    assert {:ok, ^organization_id} = Ecto.UUID.cast(organization_id)
    assert {:ok, ^place_id} = Ecto.UUID.cast(place_id)
    assert {:ok, ^polo_place_id} = Ecto.UUID.cast(polo_place_id)

    assert %{
             "place_id" => ^place_id,
             "polo_place_id" => ^polo_place_id,
             "slug" => "sabores-da-serra-centro",
             "name" => "Sabores da Serra Centro",
             "timezone" => "America/Sao_Paulo",
             "address" => %{
               "postal_code" => "12345678",
               "street" => "Rua das Flores",
               "number" => "120",
               "complement" => "Loja 2",
               "district" => "Centro"
             },
             "operators" => [
               %{
                 "organization_id" => ^organization_id,
                 "trade_name" => "Sabores da Serra",
                 "role" => "operator"
               }
             ]
           } =
             conn
             |> recycle()
             |> get("/api/v1/polos/#{fixture.polo_slug}/places")
             |> json_response(200)
             |> get_in(["data", "places"])
             |> Enum.find(&(&1["place_id"] == place_id))
  end

  test "replaying an onboarding returns the same resources without duplicating private or event data",
       %{
         conn: conn
       } do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    path = "/api/v1/polos/#{fixture.polo_slug}/backoffice/partners"
    request = onboarding_request()

    first =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "partner-onboarding-replay")
      |> post(path, request)
      |> json_response(201)

    replayed =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "partner-onboarding-replay")
      |> post(path, request)
      |> json_response(201)

    assert replayed == first

    organization_id = get_in(first, ["data", "organization", "id"])
    polo_place_id = get_in(first, ["data", "participation", "id"])

    assert %OrganizationIdentifier{
             kind: "cnpj",
             ciphertext: ciphertext,
             lookup_token: lookup_token,
             key_version: 1,
             verified_at: nil,
             revoked_at: nil
           } = Repo.get_by!(OrganizationIdentifier, organization_id: organization_id)

    assert byte_size(ciphertext) > 29
    assert :binary.match(ciphertext, "12ABC34501DE35") == :nomatch
    assert byte_size(lookup_token) == 32

    assert Repo.aggregate(
             from(identifier in OrganizationIdentifier,
               where: identifier.organization_id == ^organization_id
             ),
             :count
           ) == 1

    {:ok, %{event: event, audit: audit, outbox: outbox}} =
      Repo.transact_in_polo(admin_scope, fn repo ->
        event =
          repo.one!(
            from(event in DomainEvent,
              where:
                event.aggregate_id == ^polo_place_id and event.event_type == "partner.onboarded"
            )
          )

        audit =
          repo.one!(
            from(event in TenantEvent,
              where: event.resource_id == ^polo_place_id and event.action == "partner.onboarded"
            )
          )

        outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)
        {:ok, %{event: event, audit: audit, outbox: outbox}}
      end)

    refute inspect([event.payload, event.metadata, audit.metadata, outbox.payload]) =~
             "12ABC34501DE35"
  end

  test "a duplicate CNPJ is a stable conflict and leaves no orphan partner rows", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    path = "/api/v1/polos/#{fixture.polo_slug}/backoffice/partners"

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "partner-onboarding-original")
           |> post(path, onboarding_request())
           |> json_response(201)

    counts_before = global_partner_counts()

    duplicate_request = %{
      "organization" => %{
        "legal_name" => "Outra Empresa Ltda.",
        "trade_name" => "Outra Empresa",
        "cnpj" => "12ABC34501DE35"
      },
      "place" => %{
        "name" => "Outra Empresa Centro",
        "slug" => "outra-empresa-centro",
        "address" => %{
          "postal_code" => "87654321",
          "street" => "Rua sem Saída",
          "number" => "9",
          "district" => "Centro"
        }
      }
    }

    for _attempt <- 1..2 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "partner-onboarding-duplicate")
             |> post(path, duplicate_request)
             |> json_response(409) == %{"errors" => %{"detail" => "Conflict"}}
    end

    assert global_partner_counts() == counts_before
  end

  test "a review moderator cannot onboard partners", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    token = authenticate!(moderator_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "partner-onboarding-forbidden")
           |> post(
             "/api/v1/polos/#{fixture.polo_slug}/backoffice/partners",
             onboarding_request()
           )
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}
  end

  test "a polo admin cannot onboard into a polo where the actor has no admin membership", %{
    conn: conn
  } do
    authorized_polo = ReviewsFixtures.pending_review!()
    other_polo = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(authorized_polo, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "partner-onboarding-cross-polo")
           |> post(
             "/api/v1/polos/#{other_polo.polo_slug}/backoffice/partners",
             onboarding_request()
           )
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}
  end

  test "a duplicate place slug is a stable conflict and leaves no orphan rows", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    path = "/api/v1/polos/#{fixture.polo_slug}/backoffice/partners"

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "partner-slug-original")
           |> post(path, onboarding_request())
           |> json_response(201)

    counts_before = global_partner_counts()

    conflicting =
      put_in(onboarding_request(), ["organization", "cnpj"], Brazil.cnpj(9001))

    for _attempt <- 1..2 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "partner-slug-conflict")
             |> post(path, conflicting)
             |> json_response(409) == %{"errors" => %{"detail" => "Conflict"}}
    end

    assert global_partner_counts() == counts_before
  end

  test "reusing an idempotency key for different onboarding data conflicts", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    path = "/api/v1/polos/#{fixture.polo_slug}/backoffice/partners"

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "partner-request-conflict")
           |> post(path, onboarding_request())
           |> json_response(201)

    changed = put_in(onboarding_request(), ["place", "name"], "Outro Nome")

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "partner-request-conflict")
           |> post(path, changed)
           |> json_response(409) == %{"errors" => %{"detail" => "Conflict"}}
  end

  test "invalid CNPJ and address data are rejected before any partner row is written", %{
    conn: conn
  } do
    fixture = ReviewsFixtures.pending_review!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    counts_before = global_partner_counts()

    request = %{
      "organization" => %{
        "legal_name" => "Empresa Inválida Ltda.",
        "trade_name" => "Empresa Inválida",
        "cnpj" => "12.ABC.345/01DE-34"
      },
      "place" => %{
        "name" => "Empresa Inválida Centro",
        "slug" => "empresa-invalida-centro",
        "address" => %{
          "postal_code" => "123",
          "street" => "Rua das Flores",
          "number" => "120",
          "district" => "Centro"
        }
      }
    }

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "partner-onboarding-invalid")
           |> post("/api/v1/polos/#{fixture.polo_slug}/backoffice/partners", request)
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert global_partner_counts() == counts_before
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp onboarding_request do
    %{
      "organization" => %{
        "legal_name" => "Sabores da Serra Alimentos Ltda.",
        "trade_name" => "Sabores da Serra",
        "cnpj" => "12.ABC.345/01DE-35"
      },
      "place" => %{
        "name" => "Sabores da Serra Centro",
        "slug" => "sabores-da-serra-centro",
        "address" => %{
          "postal_code" => "12.345-678",
          "street" => "Rua das Flores",
          "number" => "120",
          "complement" => "Loja 2",
          "district" => "Centro"
        }
      }
    }
  end

  defp global_partner_counts do
    %{
      addresses: Repo.aggregate(Address, :count),
      identifiers: Repo.aggregate(OrganizationIdentifier, :count),
      organizations: Repo.aggregate(Organization, :count),
      places: Repo.aggregate(Place, :count)
    }
  end
end
