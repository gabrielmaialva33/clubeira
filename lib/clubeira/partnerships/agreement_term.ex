defmodule Clubeira.Partnerships.AgreementTerm do
  @moduledoc """
  Immutable effective commercial terms of a partner agreement.
  """

  use Clubeira.Schema

  alias Clubeira.Partnerships.PartnerAgreement
  alias Clubeira.Types.TstzRange

  schema "partner_agreement_terms" do
    belongs_to :partner_agreement, PartnerAgreement

    field :version, :integer
    field :effective_during, TstzRange
    field :settlement_model, :string
    field :redemption_sla_seconds, :integer
    field :published_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
