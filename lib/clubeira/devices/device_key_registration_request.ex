defmodule Clubeira.Devices.DeviceKeyRegistrationRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Clubeira.Devices.InstallationToken

  @primary_key false
  @public_key_bytes 32
  @proof_bytes 64

  embedded_schema do
    field :installation_token, :string, redact: true
    field :public_key, :string, redact: true
    field :proof, :string, redact: true
  end

  @type t :: %__MODULE__{
          installation_token: String.t(),
          public_key: binary(),
          proof: binary()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attributes) when is_map(attributes) do
    changeset =
      %__MODULE__{}
      |> cast(attributes, [:installation_token, :public_key, :proof])
      |> validate_required([:installation_token, :public_key, :proof])
      |> validate_length(:installation_token,
        is: InstallationToken.encoded_bytes()
      )

    with {:ok, encoded} <- apply_action(changeset, :register_device_key),
         {:ok, public_key} <- decode(encoded.public_key, @public_key_bytes),
         {:ok, proof} <- decode(encoded.proof, @proof_bytes),
         {:ok, _token_hash} <- normalize_token(encoded.installation_token),
         true <- valid_proof?(encoded.installation_token, encoded.public_key, public_key, proof) do
      {:ok,
       %__MODULE__{
         installation_token: encoded.installation_token,
         public_key: public_key,
         proof: proof
       }}
    else
      {:error, %Ecto.Changeset{} = invalid} -> {:error, invalid}
      _invalid -> {:error, add_error(changeset, :proof, "is invalid")}
    end
  end

  def new(_attributes) do
    %__MODULE__{}
    |> change()
    |> add_error(:base, "must be a map")
    |> apply_action(:register_device_key)
  end

  @spec token_hash(t()) :: binary()
  def token_hash(%__MODULE__{installation_token: token}) do
    {:ok, hash} = InstallationToken.hash(token)
    hash
  end

  @doc false
  @spec proof_message(String.t(), String.t()) :: binary()
  def proof_message(installation_token, encoded_public_key) do
    "clubeira-device-key:v1:" <> installation_token <> ":" <> encoded_public_key
  end

  defp decode(value, bytes) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) == bytes -> {:ok, decoded}
      _invalid -> :error
    end
  end

  defp decode(_value, _bytes), do: :error

  defp normalize_token(token) do
    case InstallationToken.hash(token) do
      {:ok, hash} -> {:ok, hash}
      :error -> :error
    end
  end

  defp valid_proof?(installation_token, encoded_public_key, public_key, proof) do
    :crypto.verify(
      :eddsa,
      :none,
      proof_message(installation_token, encoded_public_key),
      proof,
      [public_key, :ed25519]
    )
  end
end
