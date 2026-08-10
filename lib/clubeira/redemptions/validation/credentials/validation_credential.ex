defmodule Clubeira.Redemptions.ValidationCredential do
  @moduledoc """
  Rotatable authentication material for one tenant validation point.
  """

  use Clubeira.Schema

  alias Clubeira.Types.TstzRange

  schema "validation_credentials" do
    field :polo_id, Ecto.UUID
    field :validation_point_id, Ecto.UUID
    field :version, :integer
    field :kind, :string
    field :public_key, :binary
    field :secret_hash, :binary, redact: true
    field :valid_during, TstzRange
    field :status, :string
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          validation_point_id: Ecto.UUID.t(),
          version: pos_integer(),
          kind: String.t(),
          public_key: binary() | nil,
          secret_hash: binary() | nil,
          valid_during: Postgrex.Range.t(),
          status: String.t(),
          inserted_at: DateTime.t()
        }
end
