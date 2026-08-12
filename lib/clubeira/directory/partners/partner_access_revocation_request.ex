defmodule Clubeira.Directory.PartnerAccessRevocationRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false

  embedded_schema do
    field :reason, :string
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{reason: String.t(), idempotency_key: String.t()}

  @fields [:reason, :idempotency_key]

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
    |> update_change(:reason, &normalize_reason/1)
    |> validate_required(@fields)
    |> validate_length(:reason, min: 3, max: 500)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:revoke_partner_access)
  end

  def new(_attributes) do
    :invalid
    |> change()
    |> apply_action(:revoke_partner_access)
  end

  defp normalize_reason(reason) when is_binary(reason), do: String.trim(reason)
  defp normalize_reason(reason), do: reason
end
