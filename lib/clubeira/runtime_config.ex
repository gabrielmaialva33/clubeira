defmodule Clubeira.RuntimeConfig do
  @moduledoc """
  Validates deployment input before the supervision tree starts.

  Every failure names the offending environment variable while avoiding the
  value of secrets in error messages.
  """

  @spec integer_in_range!(String.t(), integer(), Range.t()) :: integer()
  def integer_in_range!(name, default, range) do
    value = System.get_env(name, Integer.to_string(default))

    case Integer.parse(value) do
      {parsed, ""} ->
        if parsed in range do
          parsed
        else
          raise_invalid_integer!(name, value, range)
        end

      _invalid ->
        raise_invalid_integer!(name, value, range)
    end
  end

  @spec boolean!(String.t(), boolean()) :: boolean()
  def boolean!(name, default) do
    case System.get_env(name, to_string(default)) |> String.downcase() do
      value when value in ["true", "1"] -> true
      value when value in ["false", "0"] -> false
      value -> raise "#{name} must be true, false, 1, or 0, got: #{inspect(value)}"
    end
  end

  @spec required_env!(String.t()) :: String.t()
  def required_env!(name) do
    case System.fetch_env(name) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          raise "environment variable #{name} is required"
        else
          value
        end

      :error ->
        raise "environment variable #{name} is required"
    end
  end

  @spec base64url_key!(String.t()) :: binary()
  def base64url_key!(name) do
    case Base.url_decode64(required_env!(name), padding: false) do
      {:ok, key} when byte_size(key) == 32 -> key
      _invalid -> raise "#{name} must be unpadded base64url encoding exactly 32 bytes"
    end
  end

  @spec uuid!(String.t()) :: Ecto.UUID.t()
  def uuid!(name) do
    value = required_env!(name)

    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> raise "#{name} must be a UUID"
    end
  end

  @spec provider_code!(String.t()) :: String.t()
  def provider_code!(name) do
    value = required_env!(name)

    unless String.match?(value, ~r/^[a-z0-9][a-z0-9_-]{0,62}$/) do
      raise "#{name} must be a lowercase provider code"
    end

    value
  end

  @spec absolute_https_url!(String.t()) :: String.t()
  def absolute_https_url!(name) do
    value = required_env!(name)

    unless match?(
             {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}}
             when is_binary(host) and host != "",
             URI.new(value)
           ) do
      raise "#{name} must be an absolute HTTPS URL without credentials or a fragment"
    end

    value
  end

  @spec email!(String.t()) :: String.t()
  def email!(name) do
    value = required_env!(name)

    unless Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u, value) do
      raise "#{name} must be an email address"
    end

    value
  end

  @spec host!(String.t()) :: String.t()
  def host!(name) do
    value = required_env!(name)

    case URI.new("https://" <> value) do
      {:ok,
       %URI{
         scheme: "https",
         host: host,
         port: 443,
         userinfo: nil,
         path: path,
         query: nil,
         fragment: nil
       }}
      when is_binary(host) and host != "" and path in [nil, ""] ->
        value

      _invalid ->
        raise "#{name} must be a hostname without scheme, credentials, or path"
    end
  end

  @spec database_ssl!() :: boolean() | keyword()
  def database_ssl! do
    case boolean!("DATABASE_SSL", true) do
      false ->
        false

      true ->
        case System.get_env("DATABASE_CA_CERT_FILE") do
          nil -> true
          "" -> raise_invalid_ca!()
          path -> custom_ca!(path)
        end
    end
  end

  defp custom_ca!(path) do
    with :absolute <- Path.type(path),
         true <- File.regular?(path),
         {:ok, device} <- File.open(path, [:read]) do
      File.close(device)
      [cacertfile: path]
    else
      _invalid -> raise_invalid_ca!()
    end
  end

  defp raise_invalid_ca! do
    raise "DATABASE_CA_CERT_FILE must point to a readable regular file using an absolute path"
  end

  defp raise_invalid_integer!(name, value, range) do
    raise "#{name} must be an integer in #{inspect(range)}, got: #{inspect(value)}"
  end
end
