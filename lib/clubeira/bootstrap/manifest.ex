defmodule Clubeira.Bootstrap.Manifest do
  @moduledoc """
  Validated, secret-free configuration for the first production polo.

  The manifest is deliberately strict: unknown keys fail closed and stable
  polo/operation UUIDv7 values make retries observable and deterministic.
  """

  @enforce_keys [
    :operation_id,
    :polo_id,
    :city,
    :polo,
    :legal,
    :billing,
    :admin_email
  ]
  defstruct @enforce_keys

  @root_required ~w(operation_id polo_id city polo legal billing)
  @root_optional ~w(admin_email)
  @city_keys ~w(country_code subdivision_code external_code name timezone)
  @polo_keys ~w(name slug timezone)
  @legal_keys ~w(code locale version content_uri content_file effective_from)

  @billing_keys ~w(
    provider_code
    provider_name
    merchant_account_name
    merchant_account_reference
    valid_from
  )

  @type city :: %{
          country_code: String.t(),
          subdivision_code: String.t(),
          external_code: String.t(),
          name: String.t(),
          timezone: String.t()
        }

  @type polo :: %{name: String.t(), slug: String.t(), timezone: String.t()}

  @type legal :: %{
          code: String.t(),
          locale: String.t(),
          version: 1,
          content_uri: String.t(),
          content_file: String.t(),
          effective_from: DateTime.t()
        }

  @type billing :: %{
          provider_code: String.t(),
          provider_name: String.t(),
          merchant_account_name: String.t(),
          merchant_account_reference: String.t(),
          valid_from: DateTime.t()
        }

  @type t :: %__MODULE__{
          operation_id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          city: city(),
          polo: polo(),
          legal: legal(),
          billing: billing(),
          admin_email: String.t() | nil
        }

  @type error :: {:invalid_manifest, String.t(), atom() | {:missing_keys, [String.t()]}}

  @spec new(map()) :: {:ok, t()} | {:error, error()}
  def new(attributes) when is_map(attributes) do
    with :ok <- validate_keys(attributes, @root_required, @root_optional, "root"),
         {:ok, operation_id} <- uuidv7(attributes, "operation_id"),
         {:ok, polo_id} <- uuidv7(attributes, "polo_id"),
         {:ok, city} <- city(Map.fetch!(attributes, "city")),
         {:ok, polo} <- polo(Map.fetch!(attributes, "polo")),
         {:ok, legal} <- legal(Map.fetch!(attributes, "legal")),
         {:ok, billing} <- billing(Map.fetch!(attributes, "billing")),
         {:ok, admin_email} <- optional_email(Map.get(attributes, "admin_email")) do
      {:ok,
       %__MODULE__{
         operation_id: operation_id,
         polo_id: polo_id,
         city: city,
         polo: polo,
         legal: legal,
         billing: billing,
         admin_email: admin_email
       }}
    end
  end

  def new(_attributes), do: invalid("root", :map_required)

  @spec new!(map()) :: t()
  def new!(attributes) do
    case new(attributes) do
      {:ok, manifest} -> manifest
      {:error, reason} -> raise ArgumentError, format_error(reason)
    end
  end

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = manifest) do
    canonical = %{manifest | legal: Map.delete(manifest.legal, :content_file)}

    canonical
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp city(attributes) when is_map(attributes) do
    with :ok <- validate_keys(attributes, @city_keys, [], "city"),
         {:ok, country_code} <- country_code(attributes),
         {:ok, subdivision_code} <- string(attributes, "subdivision_code", "city", 1..32),
         {:ok, external_code} <- string(attributes, "external_code", "city", 1..64),
         {:ok, name} <- string(attributes, "name", "city", 1..160),
         {:ok, timezone} <- timezone(attributes, "city") do
      {:ok,
       %{
         country_code: country_code,
         subdivision_code: subdivision_code,
         external_code: external_code,
         name: name,
         timezone: timezone
       }}
    end
  end

  defp city(_attributes), do: invalid("city", :map_required)

  defp polo(attributes) when is_map(attributes) do
    with :ok <- validate_keys(attributes, @polo_keys, [], "polo"),
         {:ok, name} <- string(attributes, "name", "polo", 1..160),
         {:ok, slug} <- slug(attributes),
         {:ok, timezone} <- timezone(attributes, "polo") do
      {:ok, %{name: name, slug: slug, timezone: timezone}}
    end
  end

  defp polo(_attributes), do: invalid("polo", :map_required)

  defp legal(attributes) when is_map(attributes) do
    with :ok <- validate_keys(attributes, @legal_keys, [], "legal"),
         {:ok, code} <- identifier(attributes, "code", "legal"),
         {:ok, locale} <- locale(attributes),
         {:ok, 1} <- version(attributes),
         {:ok, content_uri} <- https_url(attributes),
         {:ok, content_file} <- regular_file(attributes),
         {:ok, effective_from} <- datetime(attributes, "effective_from", "legal") do
      {:ok,
       %{
         code: code,
         locale: locale,
         version: 1,
         content_uri: content_uri,
         content_file: content_file,
         effective_from: effective_from
       }}
    end
  end

  defp legal(_attributes), do: invalid("legal", :map_required)

  defp billing(attributes) when is_map(attributes) do
    with :ok <- validate_keys(attributes, @billing_keys, [], "billing"),
         {:ok, provider_code} <- identifier(attributes, "provider_code", "billing"),
         {:ok, provider_name} <- string(attributes, "provider_name", "billing", 1..160),
         {:ok, account_name} <-
           string(attributes, "merchant_account_name", "billing", 1..160),
         {:ok, account_reference} <-
           string(attributes, "merchant_account_reference", "billing", 1..255),
         {:ok, valid_from} <- datetime(attributes, "valid_from", "billing") do
      {:ok,
       %{
         provider_code: provider_code,
         provider_name: provider_name,
         merchant_account_name: account_name,
         merchant_account_reference: account_reference,
         valid_from: valid_from
       }}
    end
  end

  defp billing(_attributes), do: invalid("billing", :map_required)

  defp validate_keys(attributes, required, optional, path) do
    keys = Map.keys(attributes)
    allowed = MapSet.new(required ++ optional)
    missing = Enum.reject(required, &Map.has_key?(attributes, &1))

    cond do
      Enum.any?(keys, &(not is_binary(&1) or not MapSet.member?(allowed, &1))) ->
        invalid(path, :unknown_keys)

      missing != [] ->
        invalid(path, {:missing_keys, missing})

      true ->
        :ok
    end
  end

  defp uuidv7(attributes, key) do
    value = Map.fetch!(attributes, key)

    case Ecto.UUID.cast(value) do
      {:ok, uuid} ->
        if String.at(uuid, 14) == "7", do: {:ok, uuid}, else: invalid(key, :uuidv7_required)

      :error ->
        invalid(key, :uuidv7_required)
    end
  end

  defp country_code(attributes) do
    value = attributes |> Map.fetch!("country_code") |> normalize(:upcase)

    if Regex.match?(~r/^[A-Z]{2}$/, value) do
      {:ok, value}
    else
      invalid("city.country_code", :iso_3166_alpha2_required)
    end
  rescue
    _error -> invalid("city.country_code", :string_required)
  end

  defp slug(attributes) do
    value = attributes |> Map.fetch!("slug") |> normalize(:downcase)

    if byte_size(value) in 2..80 and Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, value) do
      {:ok, value}
    else
      invalid("polo.slug", :slug_required)
    end
  rescue
    _error -> invalid("polo.slug", :string_required)
  end

  defp identifier(attributes, key, path) do
    value = attributes |> Map.fetch!(key) |> normalize(:downcase)

    if byte_size(value) in 1..80 and Regex.match?(~r/^[a-z0-9]+(?:[-_][a-z0-9]+)*$/, value) do
      {:ok, value}
    else
      invalid("#{path}.#{key}", :identifier_required)
    end
  rescue
    _error -> invalid("#{path}.#{key}", :string_required)
  end

  defp locale(attributes) do
    value = Map.fetch!(attributes, "locale")

    if is_binary(value) and byte_size(value) in 2..35 and
         Regex.match?(~r/^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/, value) do
      {:ok, value}
    else
      invalid("legal.locale", :locale_required)
    end
  end

  defp version(%{"version" => 1}), do: {:ok, 1}
  defp version(_attributes), do: invalid("legal.version", :initial_version_required)

  defp https_url(attributes) do
    value = Map.fetch!(attributes, "content_uri")

    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        {:ok, value}

      _invalid ->
        invalid("legal.content_uri", :absolute_https_url_required)
    end
  rescue
    _error -> invalid("legal.content_uri", :absolute_https_url_required)
  end

  defp regular_file(attributes) do
    path = Map.fetch!(attributes, "content_file")

    if is_binary(path) and Path.type(path) == :absolute and File.regular?(path) and
         readable?(path) do
      {:ok, path}
    else
      invalid("legal.content_file", :absolute_regular_file_required)
    end
  end

  defp readable?(path) do
    case File.open(path, [:read]) do
      {:ok, device} -> File.close(device) == :ok
      {:error, _reason} -> false
    end
  end

  defp datetime(attributes, key, path) do
    value = Map.fetch!(attributes, key)

    with true <- is_binary(value),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      normalized =
        datetime
        |> DateTime.to_unix(:microsecond)
        |> DateTime.from_unix!(:microsecond)

      {:ok, normalized}
    else
      _invalid -> invalid("#{path}.#{key}", :iso8601_datetime_required)
    end
  end

  defp timezone(attributes, path) do
    with {:ok, value} <- string(attributes, "timezone", path, 3..80) do
      if Regex.match?(~r/^[A-Za-z0-9_+-]+(?:\/[A-Za-z0-9_+-]+)+$/, value) do
        {:ok, value}
      else
        invalid("#{path}.timezone", :iana_timezone_required)
      end
    end
  end

  defp optional_email(nil), do: {:ok, nil}

  defp optional_email(value) when is_binary(value) do
    email = value |> String.trim() |> String.downcase()

    if byte_size(email) in 3..320 and Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u, email) do
      {:ok, email}
    else
      invalid("admin_email", :email_required)
    end
  end

  defp optional_email(_value), do: invalid("admin_email", :email_required)

  defp string(attributes, key, path, length_range) do
    case Map.fetch!(attributes, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if byte_size(trimmed) in length_range do
          {:ok, trimmed}
        else
          invalid("#{path}.#{key}", :invalid_length)
        end

      _value ->
        invalid("#{path}.#{key}", :string_required)
    end
  end

  defp normalize(value, casing) when is_binary(value) do
    value = String.trim(value)
    if casing == :upcase, do: String.upcase(value), else: String.downcase(value)
  end

  defp invalid(path, reason), do: {:error, {:invalid_manifest, path, reason}}

  defp format_error({:invalid_manifest, path, reason}) do
    "invalid production bootstrap manifest at #{path}: #{inspect(reason)}"
  end
end
