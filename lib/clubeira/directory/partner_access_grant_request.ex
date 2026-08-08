defmodule Clubeira.Directory.PartnerAccessGrantRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :email, :string
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{email: String.t(), idempotency_key: String.t()}

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:email, :idempotency_key])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email, :idempotency_key])
    |> validate_length(:email, max: 320)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:grant_partner_access)
  end

  def new(_attributes), do: new(%{})

  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
