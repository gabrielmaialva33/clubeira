defmodule Clubeira.Partnerships.AgreementOrganization do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "partner_agreement_organizations" do
    field :partner_agreement_id, Ecto.UUID, primary_key: true
    field :organization_id, Ecto.UUID, primary_key: true
    field :party_role, :string
    field :inserted_at, :utc_datetime_usec
  end
end
