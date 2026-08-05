defmodule Clubeira.Billing do
  @moduledoc """
  Provider-neutral sale and consumer payment boundaries.

  `place_order/2` is the authenticated member command and `list_orders/2` is
  its tenant-scoped read model. `settle_payment/2` is an internal port for a
  future provider adapter and accepts only a capture whose provider proof was
  already authenticated.
  """

  alias Clubeira.Billing.OrderPlacer
  alias Clubeira.Billing.OrderReader
  alias Clubeira.Billing.PaymentSettler
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Tenancy.Scope

  @spec place_order(Scope.t(), map()) ::
          {:ok, Order.t()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate place_order(scope, attributes), to: OrderPlacer, as: :place

  @spec list_orders(Scope.t(), map()) ::
          {:ok, %{orders: [map()], page: map()}} | {:error, term()}
  defdelegate list_orders(scope, params), to: OrderReader, as: :list

  @spec settle_payment(Scope.t(), map()) ::
          {:ok, AccessContract.t()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate settle_payment(scope, attributes), to: PaymentSettler, as: :settle
end
