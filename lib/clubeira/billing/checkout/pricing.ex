defmodule Clubeira.Billing.Pricing do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Billing.CheckoutRequest
  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.BenefitPackageItem
  alias Clubeira.Subscriptions.BenefitPackageVersion
  alias Clubeira.Subscriptions.OfferingPrice
  alias Clubeira.Subscriptions.ProductOffering
  alias Clubeira.Subscriptions.ProductOfferingPackageAssignment
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Tenancy.Scope

  @type selection :: %{
          polo: Polo.t(),
          price: OfferingPrice.t(),
          offering_version: ProductOfferingVersion.t()
        }

  @spec lock(module(), Scope.t(), CheckoutRequest.t(), DateTime.t()) ::
          {:ok, selection()} | {:error, atom()}
  def lock(repo, %Scope{} = scope, %CheckoutRequest{} = request, now) do
    with {:ok, polo} <- lock_active_polo(repo, scope.polo_id),
         {:ok, price, offering_version} <- lock_sellable_price(repo, scope, request, now),
         :ok <- ensure_benefit_package(repo, scope, offering_version.id, now) do
      {:ok, %{polo: polo, price: price, offering_version: offering_version}}
    end
  end

  defp lock_active_polo(repo, polo_id) do
    query = from polo in Polo, where: polo.id == ^polo_id, lock: "FOR SHARE"

    case repo.one(query) do
      %Polo{status: "active"} = polo -> {:ok, polo}
      %Polo{} -> {:error, :polo_unavailable}
      nil -> {:error, :polo_unavailable}
    end
  end

  defp lock_sellable_price(repo, scope, request, now) do
    query =
      from price in OfferingPrice,
        join: version in ProductOfferingVersion,
        on:
          version.id == price.product_offering_version_id and
            version.polo_id == price.polo_id,
        join: offering in ProductOffering,
        on:
          offering.id == version.product_offering_id and
            offering.polo_id == version.polo_id,
        where:
          price.id == ^request.offering_price_id and
            price.polo_id == ^scope.polo_id and
            version.id == ^request.product_offering_version_id,
        where:
          offering.status == "active" and version.status == "published" and
            price.billing_model == "subscription",
        where:
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            version.effective_during,
            type(^now, :utc_datetime_usec)
          ),
        where:
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            price.valid_during,
            type(^now, :utc_datetime_usec)
          ),
        lock: "FOR SHARE",
        select: {price, version}

    case repo.one(query) do
      {%OfferingPrice{} = price, %ProductOfferingVersion{} = version} ->
        {:ok, price, version}

      nil ->
        {:error, :offering_unavailable}
    end
  end

  defp ensure_benefit_package(repo, scope, offering_version_id, now) do
    assignment_query =
      from assignment in ProductOfferingPackageAssignment,
        join: package_version in BenefitPackageVersion,
        on:
          package_version.id == assignment.benefit_package_version_id and
            package_version.polo_id == assignment.polo_id,
        where:
          assignment.polo_id == ^scope.polo_id and
            assignment.product_offering_version_id == ^offering_version_id,
        where: package_version.status == "published",
        where:
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            assignment.valid_during,
            type(^now, :utc_datetime_usec)
          ),
        lock: "FOR SHARE",
        select: assignment.benefit_package_version_id

    case repo.one(assignment_query) do
      nil ->
        {:error, :benefit_package_unavailable}

      package_version_id ->
        if package_has_items?(repo, scope.polo_id, package_version_id) do
          :ok
        else
          {:error, :benefit_package_unavailable}
        end
    end
  end

  defp package_has_items?(repo, polo_id, package_version_id) do
    repo.exists?(
      from item in BenefitPackageItem,
        where:
          item.polo_id == ^polo_id and
            item.benefit_package_version_id == ^package_version_id
    )
  end
end
