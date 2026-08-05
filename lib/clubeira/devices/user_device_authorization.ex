defmodule Clubeira.Devices.UserDeviceAuthorization do
  @moduledoc """
  Actor-owned authorization of one installation.
  """

  use Ecto.Schema

  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "user_device_authorizations" do
    field :user_id, Ecto.UUID, primary_key: true
    field :device_installation_id, Ecto.UUID, primary_key: true
    field :status, :string
    field :authorized_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          user_id: Ecto.UUID.t(),
          device_installation_id: Ecto.UUID.t(),
          status: String.t(),
          authorized_at: DateTime.t(),
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }
end
