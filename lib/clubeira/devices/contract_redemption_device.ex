defmodule Clubeira.Devices.ContractRedemptionDevice do
  @moduledoc """
  Time-bounded authorization of one installation for a tenant contract.
  """

  use Clubeira.Schema

  alias Clubeira.Types.TstzRange

  schema "contract_redemption_devices" do
    field :polo_id, Ecto.UUID
    field :access_contract_id, Ecto.UUID
    field :contract_beneficiary_id, Ecto.UUID
    field :device_installation_id, Ecto.UUID
    field :valid_during, TstzRange
    field :status, :string
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          access_contract_id: Ecto.UUID.t(),
          contract_beneficiary_id: Ecto.UUID.t() | nil,
          device_installation_id: Ecto.UUID.t(),
          valid_during: Postgrex.Range.t(),
          status: String.t(),
          inserted_at: DateTime.t()
        }
end
