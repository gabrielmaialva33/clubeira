defmodule Clubeira.Partnerships.AgreementEdition do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "partner_agreement_editions" do
    field :partner_agreement_id, Ecto.UUID, primary_key: true
    field :polo_id, Ecto.UUID, primary_key: true
    field :edition_id, Ecto.UUID, primary_key: true
    field :inserted_at, :utc_datetime_usec
  end
end
