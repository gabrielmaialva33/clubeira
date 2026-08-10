defmodule Clubeira.Reviews.PartnerResponseRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :body, :string
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{body: String.t(), idempotency_key: String.t()}

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:body, :idempotency_key])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body, :idempotency_key])
    |> validate_length(:body, min: 2, max: 5_000)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:put_partner_response)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:put_partner_response)
  end
end
