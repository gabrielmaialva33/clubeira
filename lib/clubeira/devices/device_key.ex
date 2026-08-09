defmodule Clubeira.Devices.DeviceKey do
  @moduledoc """
  A proof-of-possession public key bound to one device installation.
  """

  use Clubeira.Schema

  alias Clubeira.Devices.DeviceInstallation
  alias Clubeira.Types.TstzRange

  schema "device_keys" do
    belongs_to :device_installation, DeviceInstallation

    field :key_thumbprint, :binary
    field :public_key, :binary, redact: true
    field :attestation_kind, :string
    field :attestation_status, :string
    field :valid_during, TstzRange
    field :revoked_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          device_installation_id: Ecto.UUID.t(),
          key_thumbprint: binary(),
          public_key: binary(),
          attestation_kind: String.t(),
          attestation_status: String.t(),
          valid_during: Postgrex.Range.t(),
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }
end
