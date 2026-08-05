defmodule Clubeira.Accounts.PasswordResetEmail do
  @moduledoc false

  import Swoosh.Email

  @spec build(String.t(), String.t(), keyword()) :: Swoosh.Email.t()
  def build(recipient, token, options) when is_binary(recipient) and is_binary(token) do
    reset_url = reset_url(Keyword.fetch!(options, :reset_url), token)

    new()
    |> to(recipient)
    |> from(Keyword.fetch!(options, :from))
    |> subject("Redefina sua senha do Clubeira")
    |> text_body("""
    Recebemos uma solicitação para redefinir sua senha do Clubeira.

    Use este link nos próximos minutos:
    #{reset_url}

    Se você não fez essa solicitação, ignore esta mensagem.
    """)
    |> html_body("""
    <p>Recebemos uma solicitação para redefinir sua senha do Clubeira.</p>
    <p><a href="#{reset_url}">Redefinir minha senha</a></p>
    <p>Se você não fez essa solicitação, ignore esta mensagem.</p>
    """)
  end

  defp reset_url(configured_url, token) do
    uri = URI.parse(configured_url)
    query = uri.query |> decode_query() |> Map.put("token", token) |> URI.encode_query()

    uri
    |> Map.put(:query, query)
    |> URI.to_string()
  end

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)
end
