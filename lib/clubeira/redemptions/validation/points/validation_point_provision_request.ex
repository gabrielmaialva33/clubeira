defmodule Clubeira.Redemptions.ValidationPointProvisionRequest do
  @moduledoc """
  Validated registration material for an API validation point.

  The caller keeps the original secret and sends only its SHA-256 digest. The
  digest is sufficient for later credential verification without making the
  provisioning endpoint a transport or persistence boundary for the secret.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @encoded_sha256_bytes 43

  embedded_schema do
    field :name, :string
    field :secret_sha256, :string, redact: true
    field :expires_at, :utc_datetime_usec
    field :idempotency_key, :string
  end

  @type t :: %__MODULE__{
          name: String.t(),
          secret_sha256: String.t(),
          expires_at: DateTime.t(),
          idempotency_key: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:name, :secret_sha256, :expires_at, :idempotency_key])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :secret_sha256, :expires_at, :idempotency_key])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:secret_sha256,
      min: @encoded_sha256_bytes,
      max: @encoded_sha256_bytes
    )
    |> validate_change(:secret_sha256, &validate_sha256/2)
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_format(:idempotency_key, ~r/^[A-Za-z0-9._:-]+$/)
    |> apply_action(:provision_validation_point)
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:provision_validation_point)
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
