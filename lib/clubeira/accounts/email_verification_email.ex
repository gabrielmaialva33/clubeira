defmodule Clubeira.Accounts.EmailVerificationEmail do
  @moduledoc false

  import Swoosh.Email

  @spec build(String.t(), String.t(), keyword()) :: Swoosh.Email.t()
  def build(recipient, token, options) when is_binary(recipient) and is_binary(token) do
    verification_url = verification_url(Keyword.fetch!(options, :verification_url), token)

    new()
    |> to(recipient)
    |> from(Keyword.fetch!(options, :from))
    |> subject("Confirme seu e-mail do Clubeira")
    |> text_body("""
    Confirme que este e-mail pertence à sua conta do Clubeira.

    Use este link dentro do prazo de validade:
    #{verification_url}

    Se você não criou essa conta, ignore esta mensagem.
    """)
    |> html_body("""
    <p>Confirme que este e-mail pertence à sua conta do Clubeira.</p>
    <p><a href="#{verification_url}">Confirmar meu e-mail</a></p>
    <p>Se você não criou essa conta, ignore esta mensagem.</p>
    """)
  end

  defp verification_url(configured_url, token) do
    uri = URI.parse(configured_url)
    query = uri.query |> decode_query() |> Map.put("token", token) |> URI.encode_query()

    uri
    |> Map.put(:query, query)
    |> URI.to_string()
  end

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)
end
