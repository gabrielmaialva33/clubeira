defmodule Clubeira.Seeds.Demo.Legal do
  @moduledoc false

  alias Clubeira.Factory
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Writer

  @content_relative_path "legal/demo-consumer-terms-v1.txt"
  @content_uri "/#{@content_relative_path}"
  @document_fields ~w(code document_kind audience status updated_at)a

  @spec run!() :: map()
  def run! do
    content_sha256 = content_sha256!()

    document =
      Writer.upsert!(
        :legal_document,
        %{
          id: id(:legal_document_consumer_terms),
          code: "consumer-terms",
          document_kind: "terms_of_service",
          audience: "consumer",
          status: "active"
        },
        @document_fields
      )

    version =
      Writer.insert_once!(:legal_document_version, %{
        id: id(:legal_document_version_consumer_terms_pt_br),
        legal_document_id: document.id,
        version: 1,
        locale: "pt-BR",
        content_uri: @content_uri,
        content_sha256: content_sha256,
        effective_during: Factory.tstz_range(~U[2026-01-01 00:00:00Z]),
        published_at: ~U[2026-01-01 00:00:00Z]
      })

    ensure_immutable_content!(version, content_sha256)

    %{document: document, version: version}
  end

  defp content_sha256! do
    :clubeira
    |> Application.app_dir("priv/static/#{@content_relative_path}")
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp ensure_immutable_content!(version, expected_sha256) do
    if version.content_uri != @content_uri or version.content_sha256 != expected_sha256 do
      raise "demo legal content changed in place; publish a new immutable document version"
    end
  end

  defp id(name), do: Ids.fetch!(name)
end
