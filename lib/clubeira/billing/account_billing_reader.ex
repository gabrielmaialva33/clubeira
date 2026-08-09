defmodule Clubeira.Billing.AccountBillingReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Billing.BillingAgreement
  alias Clubeira.Billing.ConsumerInvoice
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Tenancy.Scope

  @spec read(Scope.t()) :: {:ok, %{agreements: [map()]}} | {:error, term()}
  def read(%Scope{actor_user_id: nil}), do: {:error, :actor_required}

  def read(%Scope{} = scope) do
    Repo.transact_in_polo(scope, fn repo ->
      agreements = agreements(repo, scope)
      invoices = invoices_by_agreement(repo, scope, agreements)

      {:ok,
       %{
         agreements:
           Enum.map(agreements, fn agreement ->
             Map.put(agreement, :invoices, Map.get(invoices, agreement.id, []))
           end)
       }}
    end)
  end

  def read(_scope), do: {:error, :actor_required}

  defp agreements(repo, scope) do
    repo.all(
      from(agreement in BillingAgreement,
        join: offering in ProductOfferingVersion,
        on:
          offering.id == agreement.product_offering_version_id and
            offering.polo_id == agreement.polo_id,
        left_join: item in OrderItem,
        on:
          item.id == agreement.order_item_id and item.polo_id == agreement.polo_id and
            item.product_offering_version_id == agreement.product_offering_version_id,
        left_join: order in Order,
        on: order.id == item.order_id and order.polo_id == item.polo_id,
        where: agreement.polo_id == ^scope.polo_id and agreement.user_id == ^scope.actor_user_id,
        order_by: [desc: agreement.inserted_at, desc: agreement.id],
        select: %{
          id: agreement.id,
          status: agreement.status,
          current_period: agreement.current_period,
          next_charge_at: agreement.next_charge_at,
          cancelled_at: agreement.cancelled_at,
          inserted_at: agreement.inserted_at,
          updated_at: agreement.updated_at,
          order: %{
            id: order.id,
            order_number: order.order_number,
            status: order.status
          },
          product_offering_version: %{
            id: offering.id,
            version: offering.version,
            name: offering.name
          }
        }
      )
    )
  end

  defp invoices_by_agreement(_repo, _scope, []), do: %{}

  defp invoices_by_agreement(repo, scope, agreements) do
    agreement_ids = Enum.map(agreements, & &1.id)

    repo.all(
      from(invoice in ConsumerInvoice,
        where:
          invoice.polo_id == ^scope.polo_id and
            invoice.billing_agreement_id in ^agreement_ids,
        order_by: [desc: invoice.inserted_at, desc: invoice.id],
        lock: "FOR SHARE",
        select: %{
          id: invoice.id,
          billing_agreement_id: invoice.billing_agreement_id,
          order_id: invoice.order_id,
          invoice_number: invoice.invoice_number,
          billing_period: invoice.billing_period,
          currency: invoice.currency,
          subtotal_amount: invoice.subtotal_amount,
          discount_amount: invoice.discount_amount,
          total_amount: invoice.total_amount,
          status: invoice.status,
          issued_at: invoice.issued_at,
          due_at: invoice.due_at,
          paid_at: invoice.paid_at,
          inserted_at: invoice.inserted_at
        }
      )
    )
    |> Enum.group_by(& &1.billing_agreement_id)
  end
end
