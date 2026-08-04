defmodule Clubeira.Billing.PaymentProvider do
  @moduledoc """
  Global registry entry for a consumer or platform payment provider.
  """

  use Clubeira.Schema

  schema "payment_providers" do
    field :code, :string
    field :name, :string
    field :status, :string

    timestamps()
  end
end
