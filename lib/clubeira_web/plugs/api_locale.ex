defmodule ClubeiraWeb.Plugs.ApiLocale do
  @moduledoc """
  Negotiates the language of human-readable API messages.

  Machine-readable identifiers, enum values, and domain codes are never
  translated.
  """

  import Plug.Conn

  alias ClubeiraWeb.Gettext, as: GettextBackend

  @default_locale "en"
  @locales ~w(en pt_BR)
  @supported_locales %{
    "en" => "en",
    "pt" => "pt_BR",
    "pt-br" => "pt_BR"
  }
  @content_languages %{"en" => "en", "pt_BR" => "pt-BR"}

  @spec init(keyword()) :: keyword()
  def init(options) do
    options = Keyword.validate!(options, default_locale: @default_locale, store_in_session: false)

    unless options[:default_locale] in @locales do
      raise ArgumentError, "unsupported default locale: #{inspect(options[:default_locale])}"
    end

    options
  end

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, options) do
    default_locale = Keyword.get(options, :default_locale, @default_locale)

    locale =
      conn
      |> get_req_header("accept-language")
      |> List.first()
      |> negotiate(default_locale)

    Gettext.put_locale(GettextBackend, locale)

    conn =
      if Keyword.get(options, :store_in_session, false) do
        put_session(conn, "locale", locale)
      else
        conn
      end

    conn
    |> assign(:locale, locale)
    |> put_resp_header("content-language", Map.fetch!(@content_languages, locale))
    |> add_vary("accept-language")
  end

  defp negotiate(nil, default_locale), do: default_locale

  defp negotiate(header, default_locale)
       when is_binary(header) and byte_size(header) <= 1_024 do
    header
    |> String.split(",", trim: true)
    |> Enum.with_index()
    |> Enum.map(&parse_preference/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_tag, quality, index} -> {-quality, index} end)
    |> Enum.find_value(default_locale, fn {tag, _quality, _index} ->
      supported_locale(tag, default_locale)
    end)
  end

  defp negotiate(_oversized, default_locale), do: default_locale

  defp parse_preference({preference, index}) do
    case String.split(preference, ";", trim: true) do
      [tag] -> preference(tag, 1.0, index)
      [tag | parameters] -> preference(tag, quality(parameters), index)
    end
  end

  defp preference(tag, quality, index) when is_float(quality) and quality > 0.0 do
    {tag |> String.trim() |> String.downcase() |> String.replace("_", "-"), quality, index}
  end

  defp preference(_tag, _quality, _index), do: nil

  defp quality(parameters) do
    Enum.find_value(parameters, 1.0, fn parameter ->
      case String.split(parameter, "=", parts: 2) do
        [name, value] -> parse_quality(String.trim(name), String.trim(value))
        _invalid -> nil
      end
    end)
  end

  defp parse_quality("q", value) do
    case Float.parse(value) do
      {quality, ""} when quality >= 0.0 and quality <= 1.0 -> quality
      _invalid -> 0.0
    end
  end

  defp parse_quality(_name, _value), do: nil

  defp supported_locale("*", default_locale), do: default_locale

  defp supported_locale(tag, _default_locale) do
    Map.get(@supported_locales, tag) ||
      tag |> String.split("-", parts: 2) |> List.first() |> then(&Map.get(@supported_locales, &1))
  end

  defp add_vary(conn, dimension) do
    values =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Kernel.++([dimension])
      |> Enum.uniq()

    put_resp_header(conn, "vary", Enum.join(values, ", "))
  end
end
