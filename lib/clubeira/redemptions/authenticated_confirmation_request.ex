defmodule Clubeira.Redemptions.AuthenticatedConfirmationRequest do
  @moduledoc """
  Validated external proof presented by a validation point.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :grant, :string, redact: true
    field :validation_credential, :string, redact: true
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          grant: String.t(),
          validation_credential: String.t(),
          idempotency_key: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:grant, :validation_credential, :idempotency_key])
    |> validate_required([:grant, :validation_credential, :idempotency_key])
    |> validate_length(:grant, min: 32, max: 4_096)
    |> validate_length(:validation_credential, min: 43, max: 43)
    |> validate_change(:validation_credential, &validate_credential/2)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:confirm)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:confirm)
  end

  @spec credential_hash(t()) :: binary()
  def credential_hash(%__MODULE__{validation_credential: credential}) do
    {:ok, decoded} = Base.url_decode64(credential, padding: false)
    :crypto.hash(:sha256, decoded)
  end

  defp validate_credential(field, credential) do
    case Base.url_decode64(credential, padding: false) do
      {:ok, decoded} when byte_size(decoded) == 32 -> []
      _invalid -> [{field, "must encode exactly 32 random bytes"}]
    end
  end
end
