defmodule Clubeira.Subscriptions.ContractSuspension do
  @moduledoc """
  One non-overlapping period during which an access contract cannot be redeemed.
  """

  use Clubeira.Schema

  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.ContractEvent
  alias Clubeira.Types.TstzRange

  schema "contract_suspensions" do
    field :polo_id, Ecto.UUID
    belongs_to :access_contract, AccessContract
    belongs_to :source_contract_event, ContractEvent

    field :reason, :string
    field :suspended_during, TstzRange
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          access_contract_id: Ecto.UUID.t(),
          source_contract_event_id: Ecto.UUID.t(),
          reason: String.t(),
          suspended_during: Postgrex.Range.t(),
          inserted_at: DateTime.t()
        }
end
