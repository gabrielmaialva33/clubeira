defmodule Clubeira.Seeds.Demo.Member do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Billing
  alias Clubeira.Catalog.BenefitOfferVersion
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Writer
  alias Clubeira.Subscriptions.CycleEntitlementSubject
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Tenancy.ActorScope
  alias Clubeira.Tenancy.Scope

  @default_member_email "membro.demo@clubeira.local"
  @default_password "clubeira-demo-local"
  @user_fields ~w(email status disabled_at updated_at)a
  @access_product_fields ~w(polo_id code name status updated_at)a

  @product_offering_fields ~w(
    polo_id access_product_version_id edition_id code scope_kind sales_channel status updated_at
  )a

  @spec run!(map()) :: map()
  def run!(billing) do
    user = seed_user!()
    seed_legal_acceptance!(user)

    sobral =
      seed_subscription!(user, billing,
      key: :sobral,
      polo_id: id(:polo_sobral),
      scope_places: [
        id(:polo_place_franchise_sobral),
        id(:polo_place_local_sobral)
      ],
      items: [
        %{
          key: :franchise,
          id: id(:package_item_franchise_sobral),
          offer_version_id: id(:benefit_offer_version_franchise_sobral),
          allocation_kind: "per_place",
          polo_place_id: id(:polo_place_franchise_sobral)
        },
        %{
          key: :local,
          id: id(:package_item_local_sobral),
          offer_version_id: id(:benefit_offer_version_local_sobral),
          allocation_kind: "shared_scope",
          polo_place_id: nil
        }
      ]
    )

    londrina =
      seed_subscription!(user, billing,
      key: :londrina,
      polo_id: id(:polo_londrina),
      scope_places: [id(:polo_place_franchise_londrina)],
      items: [
        %{
          key: :franchise,
          id: id(:package_item_franchise_londrina),
          offer_version_id: id(:benefit_offer_version_franchise_londrina),
          allocation_kind: "per_place",
          polo_place_id: id(:polo_place_franchise_londrina)
        }
      ]
    )

    %{
      email: user.email,
      subscriptions: 2,
      vouchers: 3,
      polos: %{sobral: sobral, londrina: londrina}
    }
  end

  defp seed_legal_acceptance!(user) do
    scope = ActorScope.new!(user.id, id(:legal_acceptance_demo_member))

    {:ok, _acceptance} =
      Repo.transact_as_actor(scope, fn ->
        {:ok,
         Writer.insert_once!(:legal_acceptance, %{
           id: id(:legal_acceptance_demo_member),
           legal_document_version_id: id(:legal_document_version_consumer_terms_pt_br),
           user_id: user.id,
           accepted_at: ~U[2026-01-01 00:00:00Z],
           evidence: %{"source" => "demo_seed"},
           inserted_at: ~U[2026-01-01 00:00:00Z]
         })}
      end)

    :ok
  end

  defp seed_user! do
    member_email = System.get_env("CLUBEIRA_DEMO_EMAIL", @default_member_email)

    user =
      Writer.upsert!(
        :user,
        %{id: id(:member_user), email: member_email, status: "active"},
        @user_fields
      )

    password = System.get_env("CLUBEIRA_DEMO_PASSWORD", @default_password)

    unless current_password?(user, password) do
      case Accounts.set_password(user, password) do
        {:ok, _credential} ->
          :ok

        {:error, changeset} ->
          raise "invalid CLUBEIRA_DEMO_PASSWORD: #{inspect(changeset.errors)}"
      end
    end

    user
  end

  defp seed_subscription!(user, billing, options) do
    polo_id = Keyword.fetch!(options, :polo_id)

    Seeds.with_polo!(polo_id, fn ->
      polo = Repo.get!(Polo, polo_id)
      commercial = seed_commercial_definition!(polo, options)
      seed_entitlement_definition!(polo, commercial.offering_version, options)
      seed_paid_subscription!(polo, user, billing, commercial, options)
    end)
  end

  defp seed_commercial_definition!(polo, options) do
    key = Keyword.fetch!(options, :key)

    product =
      Writer.upsert!(
        :access_product,
        %{
          id: id(keyed(:access_product, key)),
          polo: polo,
          code: "clube-#{key}",
          name: "Clubeira #{humanize(key)}",
          status: "active"
        },
        @access_product_fields
      )

    product_version =
      Writer.insert_once!(:access_product_version, %{
        id: id(keyed(:access_product_version, key)),
        polo: polo,
        access_product: product,
        name: "Clubeira #{humanize(key)} mensal",
        description: "Um uso de cada voucher a cada ciclo mensal."
      })

    offering =
      Writer.upsert!(
        :product_offering,
        %{
          id: id(keyed(:product_offering, key)),
          polo: polo,
          access_product_version: product_version,
          code: "mensal-#{key}",
          scope_kind: "evergreen",
          sales_channel: "direct",
          status: "active"
        },
        @product_offering_fields
      )

    offering_version =
      Writer.insert_once!(:product_offering_version, %{
        id: id(keyed(:product_offering_version, key)),
        polo: polo,
        product_offering: offering,
        name: "Assinatura mensal #{humanize(key)}",
        description: "Benefícios independentes do outro polo."
      })

    price =
      Writer.insert_once!(:offering_price, %{
        id: id(keyed(:offering_price, key)),
        polo: polo,
        product_offering_version: offering_version
      })

    %{offering_version: offering_version, price: price}
  end

  defp seed_entitlement_definition!(polo, offering_version, options) do
    key = Keyword.fetch!(options, :key)

    package =
      Writer.insert_once!(:benefit_package, %{
        id: id(keyed(:benefit_package, key)),
        polo: polo,
        code: "beneficios-#{key}",
        name: "Benefícios #{humanize(key)}"
      })

    package_version =
      Writer.insert_once!(:benefit_package_version, %{
        id: id(keyed(:benefit_package_version, key)),
        polo: polo,
        benefit_package: package,
        name: "Benefícios #{humanize(key)} 2026"
      })

    scope =
      Writer.insert_once!(:entitlement_scope, %{
        id: id(keyed(:entitlement_scope, key)),
        polo: polo,
        benefit_package_version: package_version,
        key: "parceiros-#{key}",
        name: "Parceiros #{humanize(key)}"
      })

    seed_scope_places!(polo, scope, Keyword.fetch!(options, :scope_places))

    items =
      Enum.map(Keyword.fetch!(options, :items), fn item ->
        offer_version = Repo.get!(BenefitOfferVersion, item.offer_version_id)

        Writer.insert_once!(:benefit_package_item, %{
          id: item.id,
          polo: polo,
          benefit_package_version_id: package_version.id,
          benefit_offer_version: offer_version,
          entitlement_scope_id: scope.id,
          consumption_unit: item.allocation_kind
        })
      end)

    assignment =
      Writer.insert_once!(:product_offering_package_assignment, %{
        id: id(keyed(:package_assignment, key)),
        polo: polo,
        product_offering_version: offering_version,
        benefit_package_version: package_version
      })

    %{
      package_version: package_version,
      scope: scope,
      items: Map.new(items, &{&1.id, &1}),
      assignment: assignment
    }
  end

  defp seed_scope_places!(polo, scope, polo_place_ids) do
    Enum.each(polo_place_ids, fn polo_place_id ->
      Writer.insert_once!(:entitlement_scope_place, %{
        polo: polo,
        entitlement_scope_id: scope.id,
        polo_place: Repo.get!(PoloPlace, polo_place_id)
      })
    end)
  end

  defp seed_paid_subscription!(polo, user, billing, commercial, options) do
    key = Keyword.fetch!(options, :key)
    checkout_scope = member_scope(polo.id, user.id)

    {:ok, order} =
      Billing.place_order(checkout_scope, %{
        product_offering_version_id: commercial.offering_version.id,
        offering_price_id: commercial.price.id,
        idempotency_key: "demo-checkout-#{key}-001"
      })

    {:ok, contract} =
      Billing.settle_payment(service_scope(polo.id), %{
        order_id: order.id,
        payment_provider_id: billing.provider.id,
        merchant_account_id: billing.account.id,
        external_event_id: "demo-payment-captured-#{key}-001",
        provider_reference: "DEMO-PAYMENT-#{String.upcase(to_string(key))}-001",
        amount: order.total_amount,
        currency: order.currency,
        occurred_at: order.placed_at,
        payload: %{"scenario" => "paid_subscription", "source" => "demo_seed"}
      })

    %{
      allocations: allocation_ids(contract, Keyword.fetch!(options, :items)),
      contract_id: contract.id,
      order_id: order.id
    }
  end

  defp allocation_ids(contract, items) do
    allocations_by_item =
      EntitlementAllocation
      |> join(:inner, [allocation], subject in CycleEntitlementSubject,
        on:
          subject.id == allocation.cycle_entitlement_subject_id and
            subject.polo_id == allocation.polo_id
      )
      |> where(
        [allocation, subject],
        allocation.polo_id == ^contract.polo_id and
          subject.access_contract_id == ^contract.id
      )
      |> select([allocation], {allocation.benefit_package_item_id, allocation.id})
      |> Repo.all()
      |> Map.new()

    Map.new(items, fn item ->
      {Map.fetch!(item, :key), Map.fetch!(allocations_by_item, Map.fetch!(item, :id))}
    end)
  end

  defp member_scope(polo_id, user_id) do
    Scope.new!(polo_id,
      actor_user_id: user_id,
      request_id: Ecto.UUID.generate(version: 7, precision: :monotonic)
    )
  end

  defp service_scope(polo_id) do
    Scope.new!(polo_id, request_id: Ecto.UUID.generate(version: 7, precision: :monotonic))
  end

  defp keyed(prefix, key), do: String.to_existing_atom("#{prefix}_#{key}")
  defp humanize(key), do: key |> to_string() |> String.capitalize()
  defp id(name), do: Ids.fetch!(name)

  defp current_password?(user, password) do
    case Repo.get(PasswordCredential, user.id) do
      %PasswordCredential{password_hash: password_hash} ->
        Argon2.verify_pass(password, password_hash)

      nil ->
        false
    end
  end

end
