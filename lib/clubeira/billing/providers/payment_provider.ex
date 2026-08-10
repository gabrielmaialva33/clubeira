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

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          code: String.t(),
          name: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
