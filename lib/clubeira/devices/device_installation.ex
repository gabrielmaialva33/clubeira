defmodule Clubeira.Devices.DeviceInstallation do
  @moduledoc """
  A physical or browser installation identified by a non-recoverable token hash.
  """

  use Clubeira.Schema

  schema "device_installations" do
    field :installation_token_hash, :binary, redact: true
    field :platform, :string
    field :status, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          installation_token_hash: binary(),
          platform: String.t(),
          status: String.t(),
          first_seen_at: DateTime.t(),
          last_seen_at: DateTime.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
