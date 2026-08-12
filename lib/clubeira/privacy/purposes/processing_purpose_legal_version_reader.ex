defmodule Clubeira.Privacy.ProcessingPurposeLegalVersionReader do
  @moduledoc false

  import Ecto.Query

  alias Clubeira.Legal.Document
  alias Clubeira.Legal.DocumentVersion
  alias Clubeira.Platform.Authorization
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @default_locale "pt-BR"
  @locale_pattern ~r/^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/
  @legal_bases ~w(
    consent
    contract
    legal_obligation
    legitimate_interest
    credit_protection
    fraud_prevention
  )

  @type legal_version :: %{
          id: Ecto.UUID.t(),
          code: String.t(),
          document_kind: String.t(),
          audience: String.t(),
          locale: String.t(),
          version: pos_integer(),
          content_uri: String.t(),
          effective_from: DateTime.t(),
          effective_until: DateTime.t() | nil,
          published_at: DateTime.t()
        }

  @spec list(ActorScope.t(), map()) ::
          {:ok, [legal_version()]}
          | {:error,
             :invalid_locale | :invalid_processing_purpose | :platform_privacy_officer_required}
  def list(%ActorScope{} = scope, params) when is_map(params) and not is_struct(params) do
    with {:ok, locale} <- parse_locale(Map.get(params, "locale", @default_locale)),
         {:ok, legal_basis} <- parse_legal_basis(Map.get(params, "legal_basis")) do
      Repo.transact_as_actor(scope, &list_authorized(&1, scope, locale, legal_basis))
    end
  end

  def list(%ActorScope{}, _params), do: {:error, :invalid_locale}

  defp list_authorized(repo, scope, locale, legal_basis) do
    now = transaction_time(repo)

    with :ok <- Authorization.authorize(repo, scope, :manage_privacy, now) do
      versions =
        DocumentVersion
        |> join(:inner, [version], document in Document,
          on: document.id == version.legal_document_id
        )
        |> where(
          [version, document],
          document.status == "active" and version.locale == ^locale
        )
        |> where(
          [version],
          fragment(
            "? @> (? AT TIME ZONE 'UTC')",
            version.effective_during,
            type(^now, :utc_datetime_usec)
          )
        )
        |> with_legal_basis(legal_basis)
        |> order_by([version, document],
          asc: document.code,
          asc: version.locale,
          desc: version.version,
          asc: version.id
        )
        |> select([version, document], %{
          id: version.id,
          code: document.code,
          document_kind: document.document_kind,
          audience: document.audience,
          locale: version.locale,
          version: version.version,
          content_uri: version.content_uri,
          effective_during: version.effective_during,
          published_at: version.published_at
        })
        |> repo.all()

      {:ok, Enum.map(versions, &legal_version_data/1)}
    end
  end

  defp with_legal_basis(query, "consent") do
    where(
      query,
      [_version, document],
      document.audience == "consumer" and document.document_kind == "consent_notice"
    )
  end

  defp with_legal_basis(query, _other_basis), do: query

  defp legal_version_data(version) do
    %{
      id: version.id,
      code: version.code,
      document_kind: version.document_kind,
      audience: version.audience,
      locale: version.locale,
      version: version.version,
      content_uri: version.content_uri,
      effective_from: version.effective_during.lower,
      effective_until: range_upper(version.effective_during.upper),
      published_at: version.published_at
    }
  end

  defp range_upper(:unbound), do: nil
  defp range_upper(value), do: value

  defp parse_locale(locale) when is_binary(locale) and byte_size(locale) in 2..35 do
    if String.valid?(locale) and Regex.match?(@locale_pattern, locale),
      do: {:ok, locale},
      else: {:error, :invalid_locale}
  end

  defp parse_locale(_locale), do: {:error, :invalid_locale}

  defp parse_legal_basis(nil), do: {:ok, nil}
  defp parse_legal_basis(legal_basis) when legal_basis in @legal_bases, do: {:ok, legal_basis}
  defp parse_legal_basis(_legal_basis), do: {:error, :invalid_processing_purpose}

  defp transaction_time(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end
end
