defmodule Clubeira.Directory.OrganizationIdentifier do
  @moduledoc """
  Encrypted, searchable identifier belonging to an organization.
  """

  use Clubeira.Schema

  import Ecto.Changeset

  alias Clubeira.Directory.Organization

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          kind: String.t(),
          ciphertext: binary(),
          lookup_token: binary(),
          key_version: pos_integer(),
          verified_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }

  schema "organization_identifiers" do
    belongs_to :organization, Organization

    field :kind, :string
    field :ciphertext, :binary
    field :lookup_token, :binary
    field :key_version, :integer
    field :verified_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @spec create_changeset(Organization.t(), String.t(), map(), DateTime.t()) ::
          Ecto.Changeset.t()
  def create_changeset(%Organization{} = organization, kind, sealed, now) do
    %__MODULE__{
      organization_id: organization.id,
      kind: kind,
      ciphertext: Map.fetch!(sealed, :ciphertext),
      lookup_token: Map.fetch!(sealed, :lookup_token),
      key_version: Map.fetch!(sealed, :key_version),
      inserted_at: now
    }
    |> change()
    |> unique_constraint(:lookup_token,
      name: :organization_identifiers_active_lookup_uidx
    )
  end
end
