defmodule Clubeira.Polos.PoloPolicyVersion do
  @moduledoc """
  Versioned operational and redemption policies for a polo.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Types.TstzRange

  schema "polo_policy_versions" do
    belongs_to :polo, Polo

    field :version, :integer
    field :effective_during, TstzRange
    field :redemption_confirmation_mode, :string
    field :redemption_device_policy, :string
    field :max_authorized_devices, :integer
    field :delinquency_mode, :string
    field :delinquency_grace_days, :integer
    field :review_policy, :string
    field :published_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
