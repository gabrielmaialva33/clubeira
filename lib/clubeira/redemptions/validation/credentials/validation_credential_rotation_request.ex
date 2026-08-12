defmodule Clubeira.Redemptions.ValidationCredentialRotationRequest do
  @moduledoc """
  Validated material for rotating an API validation credential.

  The caller keeps the new secret and sends only its SHA-256 digest.
  """

  use Ecto.Schema

  import Ecto.Changeset, except: [change: 1, change: 2]

  @primary_key false
  @encoded_sha256_bytes 43
  @fields [:secret_sha256, :expires_at, :idempotency_key]

  embedded_schema do
    field :secret_sha256, :string, redact: true
    field :expires_at, :utc_datetime_usec
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          secret_sha256: String.t(),
          expires_at: DateTime.t(),
          idempotency_key: String.t()
        }

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
    |> validate_required([:secret_sha256, :expires_at, :idempotency_key])
    |> validate_length(:secret_sha256,
      min: @encoded_sha256_bytes,
      max: @encoded_sha256_bytes
    )
    |> validate_change(:secret_sha256, &validate_sha256/2)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:rotate_validation_credential)
  end

  def new(_attributes) do
    :invalid
    |> change()
    |> apply_action(:rotate_validation_credential)
  end

  @spec secret_hash(t()) :: binary()
  def secret_hash(%__MODULE__{secret_sha256: encoded}) do
    {:ok, digest} = Base.url_decode64(encoded, padding: false)
    digest
  end

  defp validate_sha256(field, encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, digest} when byte_size(digest) == 32 -> []
      _invalid -> [{field, "must encode exactly one SHA-256 digest"}]
    end
  end
end
