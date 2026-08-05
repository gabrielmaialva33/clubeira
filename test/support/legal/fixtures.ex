defmodule Clubeira.LegalFixtures do
  @moduledoc false

  alias Clubeira.Factory
  alias Clubeira.Repo

  @spec registration_terms!() :: map()
  def registration_terms! do
    document_id = uuid7()
    version_id = uuid7()
    now = DateTime.utc_now(:microsecond)

    {1, nil} =
      Repo.insert_all("legal_documents", [
        %{
          id: Ecto.UUID.dump!(document_id),
          code: "consumer-terms-#{document_id}",
          document_kind: "terms_of_service",
          audience: "consumer",
          status: "active",
          inserted_at: now,
          updated_at: now
        }
      ])

    {1, nil} =
      Repo.insert_all("legal_document_versions", [
        %{
          id: Ecto.UUID.dump!(version_id),
          legal_document_id: Ecto.UUID.dump!(document_id),
          version: 1,
          locale: "pt-BR",
          content_uri: "/legal/demo-consumer-terms-v1.txt",
          content_sha256: :crypto.hash(:sha256, "demo consumer terms v1"),
          effective_during: Factory.tstz_range(DateTime.add(now, -60)),
          published_at: DateTime.add(now, -60),
          inserted_at: now
        }
      ])

    %{document_id: document_id, version_id: version_id}
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
