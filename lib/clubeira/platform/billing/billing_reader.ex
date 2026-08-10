defmodule Clubeira.Platform.BillingReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Platform.Feature
  alias Clubeira.Platform.Invoice
  alias Clubeira.Platform.InvoiceItem
  alias Clubeira.Platform.Payment
  alias Clubeira.Platform.Plan
  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Platform.PlanVersionFeature
  alias Clubeira.Platform.PoloSubscription
  alias Clubeira.Platform.Price
  alias Clubeira.Polos.Authorization
  alias Clubeira.Polos.Polo
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @spec read(Scope.t()) :: {:ok, map()} | {:error, atom()}
  def read(%Scope{actor_user_id: nil}), do: {:error, :billing_admin_required}

  def read(%Scope{} = scope) do
    Repo.transact_in_polo(scope, &read_in_scope(&1, scope))
  end

  def read(_scope), do: {:error, :billing_admin_required}

  defp read_in_scope(repo, scope) do
    now = transaction_time(repo)

    with {:ok, _polo} <- fetch_active_polo(repo, scope.polo_id),
         :ok <- Authorization.authorize(repo, scope, :manage_billing, now) do
      billing_view(repo, scope)
    end
  end

  defp billing_view(repo, scope) do
    case latest_subscription(repo, scope) do
      nil -> {:ok, %{subscription: nil, invoices: []}}
      subscription -> {:ok, build_view(repo, scope, subscription)}
    end
  end

  defp fetch_active_polo(repo, polo_id) do
    case repo.one(from(polo in Polo, where: polo.id == ^polo_id, lock: "FOR SHARE")) do
      %Polo{status: "active"} = polo -> {:ok, polo}
      _missing_or_inactive -> {:error, :polo_not_found}
    end
  end

  defp latest_subscription(repo, scope) do
    repo.one(
      from(subscription in PoloSubscription,
        where: subscription.polo_id == ^scope.polo_id,
        order_by: [desc: subscription.inserted_at, desc: subscription.id],
        limit: 1,
        lock: "FOR SHARE"
      )
    )
  end

  defp build_view(repo, scope, subscription) do
    graph = plan_graph!(repo, subscription)
    features = features(repo, graph.version.id)

    %{
      subscription: %{
        id: subscription.id,
        status: subscription.status,
        current_period: range(subscription.current_period),
        next_charge_at: subscription.next_charge_at,
        cancelled_at: subscription.cancelled_at,
        inserted_at: subscription.inserted_at,
        updated_at: subscription.updated_at,
        plan: %{
          code: graph.plan.code,
          name: graph.plan.name,
          version: graph.version.version,
          version_name: graph.version.name,
          features: features,
          price: %{
            currency: graph.price.currency,
            amount: graph.price.amount,
            billing_interval_unit: graph.price.billing_interval_unit,
            billing_interval_count: graph.price.billing_interval_count
          }
        }
      },
      invoices: invoices(repo, scope, subscription.id)
    }
  end

  defp plan_graph!(repo, subscription) do
    repo.one!(
      from(price in Price,
        join: version in PlanVersion,
        on:
          version.id == price.platform_plan_version_id and
            version.id == ^subscription.platform_plan_version_id,
        join: plan in Plan,
        on: plan.id == version.platform_plan_id,
        where: price.id == ^subscription.platform_price_id,
        select: %{price: price, version: version, plan: plan}
      )
    )
  end

  defp features(repo, version_id) do
    repo.all(
      from(assignment in PlanVersionFeature,
        join: feature in Feature,
        on:
          feature.id == assignment.platform_feature_id and
            feature.value_kind == assignment.value_kind,
        where: assignment.platform_plan_version_id == ^version_id,
        order_by: [asc: feature.key],
        select: %{
          key: feature.key,
          name: feature.name,
          value_kind: assignment.value_kind,
          boolean_value: assignment.boolean_value,
          integer_value: assignment.integer_value
        }
      )
    )
  end

  defp invoices(repo, scope, subscription_id) do
    repo.all(
      from(invoice in Invoice,
        where:
          invoice.polo_id == ^scope.polo_id and
            invoice.polo_platform_subscription_id == ^subscription_id,
        order_by: [desc: invoice.inserted_at, desc: invoice.id],
        lock: "FOR SHARE"
      )
    )
    |> Enum.map(fn invoice ->
      %{
        id: invoice.id,
        invoice_number: invoice.invoice_number,
        billing_period: range(invoice.billing_period),
        currency: invoice.currency,
        subtotal_amount: invoice.subtotal_amount,
        discount_amount: invoice.discount_amount,
        total_amount: invoice.total_amount,
        status: invoice.status,
        issued_at: invoice.issued_at,
        due_at: invoice.due_at,
        paid_at: invoice.paid_at,
        inserted_at: invoice.inserted_at,
        items: invoice_items(repo, scope, invoice.id),
        payment: invoice_payment(repo, scope, invoice.id)
      }
    end)
  end

  defp invoice_items(repo, scope, invoice_id) do
    repo.all(
      from(item in InvoiceItem,
        where: item.polo_id == ^scope.polo_id and item.platform_invoice_id == ^invoice_id,
        order_by: [asc: item.inserted_at, asc: item.id],
        select: %{
          id: item.id,
          item_kind: item.item_kind,
          description: item.description,
          quantity: item.quantity,
          unit_amount: item.unit_amount,
          total_amount: item.total_amount
        }
      )
    )
  end

  defp invoice_payment(repo, scope, invoice_id) do
    repo.one(
      from(payment in Payment,
        where: payment.polo_id == ^scope.polo_id and payment.platform_invoice_id == ^invoice_id,
        order_by: [desc: payment.inserted_at, desc: payment.id],
        limit: 1,
        select: %{
          id: payment.id,
          currency: payment.currency,
          amount: payment.amount,
          status: payment.status,
          paid_at: payment.paid_at,
          inserted_at: payment.inserted_at
        }
      )
    )
  end

  defp range(nil), do: nil

  defp range(value) do
    %{starts_at: value.lower, ends_at: value.upper}
  end

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
