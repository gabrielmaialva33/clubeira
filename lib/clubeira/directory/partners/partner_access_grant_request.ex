defmodule Clubeira.Directory.PartnerAccessGrantRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false

  embedded_schema do
    field :email, :string
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{email: String.t(), idempotency_key: String.t()}

  @fields [:email, :idempotency_key]

  @spec change(term()) :: Ecto.Changeset.t()
  def change(attributes \\ %{})

  def change(attributes) when is_map(attributes) and not is_struct(attributes) do
    cast(%__MODULE__{}, attributes, @fields)
  end

  def change(_attributes) do
    %__MODULE__{}
    |> Ecto.Changeset.change()
    |> add_error(:base, "must be a map")
  end

  @spec new(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) and not is_struct(attributes) do
    attributes
    |> change()
    |> update_change(:email, &normalize_email/1)
    |> validate_required(@fields)
    |> validate_length(:email, max: 320)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:grant_partner_access)
  end

  def new(_attributes) do
    :invalid
    |> change()
    |> apply_action(:grant_partner_access)
  end

  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
