defmodule Clubeira.Seeds.Demo.Legal do
  @moduledoc false

  alias Clubeira.Factory
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Writer

  @document_fields ~w(code document_kind audience status updated_at)a

  @spec run!() :: map()
  def run! do
    terms =
      seed_document!(
        :legal_document_consumer_terms,
        :legal_document_version_consumer_terms_pt_br,
        "consumer-terms",
        "terms_of_service",
        "legal/demo-consumer-terms-v1.txt"
      )

    consent =
      seed_document!(
        :legal_document_consumer_consent,
        :legal_document_version_consumer_consent_pt_br,
        "consumer-communications-consent",
        "consent_notice",
        "legal/demo-consumer-consent-v1.txt"
      )

    %{document: terms.document, version: terms.version, consent: consent}
  end

  defp seed_document!(document_id, version_id, code, document_kind, relative_path) do
    content_uri = "/#{relative_path}"
    content_sha256 = content_sha256!(relative_path)

    document =
      Writer.upsert!(
        :legal_document,
        %{
          id: id(document_id),
          code: code,
          document_kind: document_kind,
          audience: "consumer",
          status: "active"
        },
        @document_fields
      )

    version =
      Writer.insert_once!(:legal_document_version, %{
        id: id(version_id),
        legal_document_id: document.id,
        version: 1,
        locale: "pt-BR",
        content_uri: content_uri,
        content_sha256: content_sha256,
        effective_during: Factory.tstz_range(~U[2026-01-01 00:00:00Z]),
        published_at: ~U[2026-01-01 00:00:00Z]
      })

    ensure_immutable_content!(version, content_uri, content_sha256)
    %{document: document, version: version}
  end

  defp content_sha256!(relative_path) do
    :clubeira
    |> Application.app_dir("priv/static/#{relative_path}")
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp ensure_immutable_content!(version, expected_uri, expected_sha256) do
    if version.content_uri != expected_uri or version.content_sha256 != expected_sha256 do
      raise "demo legal content changed in place; publish a new immutable document version"
    end
  end

  defp id(name), do: Ids.fetch!(name)
end
