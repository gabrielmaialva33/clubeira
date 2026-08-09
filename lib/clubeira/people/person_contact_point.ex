defmodule Clubeira.People.PersonContactPoint do
  @moduledoc """
  Encrypted contact endpoint owned by one civil identity.
  """

  use Clubeira.Schema

  import Ecto.Changeset

  schema "person_contact_points" do
    field :person_id, Ecto.UUID
    field :kind, :string
    field :ciphertext, :binary, redact: true
    field :lookup_token, :binary, redact: true
    field :key_version, :integer
    field :is_primary, :boolean
    field :verified_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          person_id: Ecto.UUID.t(),
          kind: String.t(),
          ciphertext: binary(),
          lookup_token: binary(),
          key_version: pos_integer(),
          is_primary: boolean(),
          verified_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc false
  @spec create_changeset(Ecto.UUID.t(), String.t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def create_changeset(person_id, kind, sealed, %DateTime{} = now) do
    %__MODULE__{}
    |> change(%{
      person_id: person_id,
      kind: kind,
      ciphertext: sealed.ciphertext,
      lookup_token: sealed.lookup_token,
      key_version: sealed.key_version,
      is_primary: true,
      inserted_at: now,
      updated_at: now
    })
    |> unique_constraint(:lookup_token, name: :person_contact_points_active_lookup_uidx)
    |> unique_constraint(:is_primary, name: :person_contact_points_primary_uidx)
  end
end
