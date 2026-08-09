defmodule Clubeira.Partnerships.PartnerAgreement do
  @moduledoc """
  Global legal identity of a partner agreement.
  """

  use Clubeira.Schema

  alias Clubeira.Types.TstzRange

  schema "partner_agreements" do
    field :agreement_number, :string
    field :name, :string
    field :valid_during, TstzRange
    field :status, :string
    field :signed_at, :utc_datetime_usec
    field :terminated_at, :utc_datetime_usec

    timestamps()
  end
end
