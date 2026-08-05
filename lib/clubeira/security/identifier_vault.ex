defmodule Clubeira.Security.IdentifierVault do
  @moduledoc """
  Encrypts business identifiers and derives a stable keyed lookup token.

  Encryption keys are versioned independently from the lookup key so ciphertext
  can rotate without changing the uniqueness identity of an identifier.
  """

  @format_version 1
  @nonce_size 12
  @tag_size 16

  @type sealed :: %{
          ciphertext: binary(),
          lookup_token: binary(),
          key_version: pos_integer()
        }

  @spec seal(String.t(), String.t()) :: sealed()
  def seal(kind, plaintext) when is_binary(kind) and is_binary(plaintext) do
    config = Application.fetch_env!(:clubeira, __MODULE__)
    key_version = Keyword.fetch!(config, :active_key_version)
    encryption_key = config |> Keyword.fetch!(:encryption_keys) |> Map.fetch!(key_version)
    lookup_key = Keyword.fetch!(config, :lookup_key)
    validate_key!(encryption_key, :encryption_key)
    validate_key!(lookup_key, :lookup_key)

    nonce = :crypto.strong_rand_bytes(@nonce_size)
    aad = associated_data(kind, key_version)

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        encryption_key,
        nonce,
        plaintext,
        aad,
        @tag_size,
        true
      )

    %{
      ciphertext: <<@format_version, nonce::binary, tag::binary, encrypted::binary>>,
      lookup_token: :crypto.mac(:hmac, :sha256, lookup_key, kind <> <<0>> <> plaintext),
      key_version: key_version
    }
  end

  defp associated_data(kind, key_version),
    do: "clubeira:identifier:#{kind}:v#{key_version}"

  defp validate_key!(key, _name) when is_binary(key) and byte_size(key) == 32, do: :ok

  defp validate_key!(_key, name) do
    raise ArgumentError, "#{name} must contain exactly 32 bytes"
  end
end
