defmodule Clubeira.Subscriptions.CycleEntitlementSubject do
  @moduledoc """
  Identifies whether a cycle allowance is shared by a contract or isolated per beneficiary.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitCycle

  schema "cycle_entitlement_subjects" do
    belongs_to :polo, Polo
    belongs_to :access_contract, AccessContract
    belongs_to :benefit_cycle, BenefitCycle

    field :contract_beneficiary_id, Ecto.UUID
    field :subject_kind, :string
    field :inserted_at, :utc_datetime_usec
  end
end
