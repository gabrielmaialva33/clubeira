defmodule Clubeira.Legal do
  @moduledoc """
  Versioned legal documents and immutable acceptance evidence.

  Registration fails closed unless the client accepts every currently effective
  consumer terms-of-service version for its locale.
  """

  import Ecto.Query

  alias Clubeira.Accounts.User
  alias Clubeira.Legal.Acceptance
  alias Clubeira.Legal.Document
  alias Clubeira.Legal.DocumentVersion
  alias Clubeira.Repo

  @default_locale "pt-BR"
  @locale_pattern ~r/^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/

  @type registration_document :: %{
          id: Ecto.UUID.t(),
          code: String.t(),
          document_kind: String.t(),
          locale: String.t(),
          version: pos_integer(),
          content_uri: String.t(),
          content_sha256: String.t()
        }

  @spec list_registration_documents(map()) ::
          {:ok, [registration_document()]} | {:error, :invalid_locale}
  def list_registration_documents(params) when is_map(params) do
    with {:ok, locale} <- parse_locale(Map.get(params, "locale", @default_locale)) do
      {:ok,
       Repo.all(
         from [document, version] in current_registration_documents_query(locale),
           order_by: [asc: document.code],
           select: %{
             id: version.id,
             code: document.code,
             document_kind: document.document_kind,
             locale: version.locale,
             version: version.version,
             content_uri: version.content_uri,
             content_sha256: fragment("encode(?, 'hex')", version.content_sha256)
           }
       )}
    end
  end

  def list_registration_documents(_params), do: {:error, :invalid_locale}

  @doc false
  @spec validate_registration_acceptances(module(), [Ecto.UUID.t()], String.t()) ::
          :ok | {:error, :legal_acceptance_invalid | :legal_documents_unavailable}
  def validate_registration_acceptances(repo, version_ids, locale)
      when is_list(version_ids) and is_binary(locale) do
    required_ids =
      repo.all(
        from [_document, version] in current_registration_documents_query(locale),
          select: version.id
      )

    cond do
      required_ids == [] -> {:error, :legal_documents_unavailable}
      MapSet.new(required_ids) == MapSet.new(version_ids) -> :ok
      true -> {:error, :legal_acceptance_invalid}
    end
  end

  @doc false
  @spec accept_registration!(module(), User.t(), [Ecto.UUID.t()], DateTime.t()) :: :ok
  def accept_registration!(repo, %User{} = user, version_ids, %DateTime{} = accepted_at) do
    Enum.each(version_ids, fn version_id ->
      %Acceptance{
        legal_document_version_id: version_id,
        user_id: user.id,
        accepted_at: accepted_at,
        evidence: %{"source" => "registration"},
        inserted_at: accepted_at
      }
      |> repo.insert!()
    end)

    :ok
  end

  defp current_registration_documents_query(locale) do
    from document in Document,
      join: version in DocumentVersion,
      on: version.legal_document_id == document.id,
      where:
        document.status == "active" and
          document.audience == "consumer" and
          document.document_kind == "terms_of_service" and
          version.locale == ^locale and
          fragment("? @> statement_timestamp()", version.effective_during)
  end

  defp parse_locale(locale)
       when is_binary(locale) and byte_size(locale) in 2..35 do
    if Regex.match?(@locale_pattern, locale), do: {:ok, locale}, else: {:error, :invalid_locale}
  end

  defp parse_locale(_locale), do: {:error, :invalid_locale}
end
