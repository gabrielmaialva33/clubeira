defmodule Clubeira.People.PersonIdentifier do
  @moduledoc """
  Encrypted civil identifier with a keyed token used only for uniqueness lookup.
  """

  use Clubeira.Schema

  import Ecto.Changeset

  schema "person_identifiers" do
    field :person_id, Ecto.UUID
    field :kind, :string
    field :ciphertext, :binary, redact: true
    field :lookup_token, :binary, redact: true
    field :key_version, :integer
    field :verified_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          person_id: Ecto.UUID.t(),
          kind: String.t(),
          ciphertext: binary(),
          lookup_token: binary(),
          key_version: pos_integer(),
          verified_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
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
      inserted_at: now
    })
    |> unique_constraint(:lookup_token, name: :person_identifiers_active_lookup_uidx)
  end
end
