defmodule Clubeira.Platform.SubscriptionStartRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields ~w(platform_price_id idempotency_key)a

  embedded_schema do
    field :platform_price_id, Ecto.UUID
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          platform_price_id: Ecto.UUID.t(),
          idempotency_key: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:start_platform_subscription)
  end

  def new(_attributes), do: new(%{})
end
