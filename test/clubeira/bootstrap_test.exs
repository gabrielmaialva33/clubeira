defmodule Clubeira.BootstrapTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts.User
  alias Clubeira.Audit.SystemEvent
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Billing.PoloMerchantAccount
  alias Clubeira.Bootstrap
  alias Clubeira.Bootstrap.Manifest
  alias Clubeira.Directory.City
  alias Clubeira.Legal.Document
  alias Clubeira.Legal.DocumentVersion
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloMembership
  alias Clubeira.Polos.PoloMembershipRole
  alias Clubeira.Polos.PoloRole
  alias Clubeira.Polos.PoloRoute
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  test "creates the production foundation atomically and grants a verified initial admin" do
    manifest = manifest!()

    assert {:error, :migrator_role_required} = Bootstrap.run(manifest)
    assert Repo.aggregate(City, :count) == 0

    assert {:ok, first} = as_owner(fn -> Bootstrap.run(manifest) end)
    assert first.admin_status == :pending_registration

    assert Repo.aggregate(City, :count) == 1
    assert Repo.aggregate(PoloRoute, :count) == 1
    assert Repo.aggregate(Document, :count) == 1
    assert Repo.aggregate(DocumentVersion, :count) == 1
    assert Repo.aggregate(PaymentProvider, :count) == 1
    assert Repo.aggregate(MerchantAccount, :count) == 1
    assert Repo.aggregate(SystemEvent, :count) == 1

    assert {:ok, repeated} = as_owner(fn -> Bootstrap.run(manifest) end)
    assert repeated == first
    assert Repo.aggregate(SystemEvent, :count) == 1

    user =
      as_owner(fn ->
        Repo.insert!(%User{
          email: manifest.admin_email,
          status: "active",
          inserted_at: now(),
          updated_at: now()
        })
      end)

    assert {:ok, pending} = as_owner(fn -> Bootstrap.run(manifest) end)
    assert pending.admin_status == :pending_verification
    assert scoped_count(manifest.polo_id, PoloMembership) == 0

    as_owner(fn ->
      user
      |> Ecto.Changeset.change(email_verified_at: now(), updated_at: now())
      |> Repo.update!()
    end)

    assert {:ok, granted} = as_owner(fn -> Bootstrap.run(manifest) end)
    assert granted.admin_status == :granted
    assert scoped_count(manifest.polo_id, Polo) == 1
    assert scoped_count(manifest.polo_id, PoloRole) == 1
    assert scoped_count(manifest.polo_id, PoloMembership) == 1
    assert scoped_count(manifest.polo_id, PoloMembershipRole) == 1
    assert scoped_count(manifest.polo_id, PoloMerchantAccount) == 1
    assert scoped_count(manifest.polo_id, TenantEvent) == 1

    assert {:ok, final} = as_owner(fn -> Bootstrap.run(manifest) end)
    assert final.admin_status == :already_granted
    assert scoped_count(manifest.polo_id, TenantEvent) == 1
  end

  test "fails closed when an existing natural identity has divergent attributes" do
    manifest = manifest!()

    as_owner(fn ->
      Repo.insert!(%City{
        country_code: manifest.city.country_code,
        subdivision_code: manifest.city.subdivision_code,
        external_code: manifest.city.external_code,
        name: "Outra cidade",
        timezone: manifest.city.timezone,
        status: "active",
        inserted_at: now(),
        updated_at: now()
      })
    end)

    assert {:error, {:bootstrap_drift, :city, [:name]}} =
             as_owner(fn -> Bootstrap.run(manifest) end)

    assert Repo.aggregate(Document, :count) == 0
    assert Repo.aggregate(SystemEvent, :count) == 0
  end

  test "detects scoped drift without duplicating the completed operation audit" do
    manifest = manifest!()
    assert {:ok, _result} = as_owner(fn -> Bootstrap.run(manifest) end)

    as_owner(fn ->
      scope = Scope.new!(manifest.polo_id)

      assert {:ok, :updated} =
               Repo.transact_in_polo(scope, fn ->
                 Polo
                 |> Repo.get!(manifest.polo_id)
                 |> Ecto.Changeset.change(name: "Nome divergente")
                 |> Repo.update!()

                 {:ok, :updated}
               end)
    end)

    assert {:error, {:bootstrap_drift, :polo, [:name]}} =
             as_owner(fn -> Bootstrap.run(manifest) end)

    assert Repo.aggregate(SystemEvent, :count) == 1
  end

  defp manifest! do
    {:ok, manifest} =
      Manifest.new(%{
        "operation_id" => Ecto.UUID.generate(version: 7),
        "polo_id" => Ecto.UUID.generate(version: 7),
        "city" => %{
          "country_code" => "BR",
          "subdivision_code" => "CE",
          "external_code" => "#{System.unique_integer([:positive])}",
          "name" => "Sobral",
          "timezone" => "America/Fortaleza"
        },
        "polo" => %{
          "name" => "Clubeira Sobral",
          "slug" => "sobral-#{System.unique_integer([:positive])}",
          "timezone" => "America/Fortaleza"
        },
        "legal" => %{
          "code" => "consumer-terms-#{System.unique_integer([:positive])}",
          "locale" => "pt-BR",
          "version" => 1,
          "content_uri" => "https://clubeira.example/legal/consumer-terms-v1.txt",
          "content_file" =>
            Application.app_dir(:clubeira, "priv/static/legal/demo-consumer-terms-v1.txt"),
          "effective_from" => "2026-08-08T12:00:00Z"
        },
        "billing" => %{
          "provider_code" => "mercado-pago-#{System.unique_integer([:positive])}",
          "provider_name" => "Mercado Pago",
          "merchant_account_name" => "Clubeira Sobral",
          "merchant_account_reference" => "clubeira-sobral-#{System.unique_integer([:positive])}",
          "valid_from" => "2026-08-08T12:00:00Z"
        },
        "admin_email" => "admin-#{System.unique_integer([:positive])}@clubeira.example"
      })

    manifest
  end

  defp scoped_count(polo_id, schema) do
    scope = Scope.new!(polo_id)

    assert {:ok, count} =
             Repo.transact_in_polo(scope, fn -> {:ok, Repo.aggregate(schema, :count)} end)

    count
  end

  defp as_owner(operation), do: Clubeira.TestDatabaseRole.as_owner(operation)
  defp now, do: DateTime.utc_now(:microsecond)
end
