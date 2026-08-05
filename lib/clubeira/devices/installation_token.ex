defmodule Clubeira.Devices.InstallationToken do
  @moduledoc false

  @decoded_bytes 32
  @encoded_bytes 43

  @spec encoded_bytes() :: pos_integer()
  def encoded_bytes, do: @encoded_bytes

  @spec hash(String.t()) :: {:ok, binary()} | :error
  def hash(token) when is_binary(token) and byte_size(token) == @encoded_bytes do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} when byte_size(decoded) == @decoded_bytes ->
        {:ok, :crypto.hash(:sha256, decoded)}

      _invalid ->
        :error
    end
  end

  def hash(_token), do: :error
end
