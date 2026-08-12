defmodule Clubeira.Privacy.ProcessingPurposeLegalVersionReaderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Factory
  alias Clubeira.Privacy
  alias Clubeira.PrivacyFixtures
  alias Clubeira.Tenancy.ActorScope

  test "a privacy officer lists an eligible consent notice with semantic context" do
    now = DateTime.utc_now(:microsecond)

    %{document: document, version: version} =
      insert_legal_version!(
        document_kind: "consent_notice",
        audience: "consumer",
        locale: "pt-BR",
        effective_during: Factory.tstz_range(DateTime.add(now, -60))
      )

    officer = Factory.insert(:user)
    PrivacyFixtures.privacy_officer!(officer)
    scope = ActorScope.new!(officer.id, Ecto.UUID.generate(version: 7))

    assert {:ok, [listed]} =
             Privacy.list_processing_purpose_legal_versions(scope, %{
               "locale" => "pt-BR",
               "legal_basis" => "consent"
             })

    assert listed == %{
             id: version.id,
             code: document.code,
             document_kind: "consent_notice",
             audience: "consumer",
             locale: "pt-BR",
             version: 1,
             content_uri: version.content_uri,
             effective_from: version.effective_during.lower,
             effective_until: nil,
             published_at: version.published_at
           }
  end

  test "consent options enforce current effectiveness, active documents and exact locale" do
    now = DateTime.utc_now(:microsecond)
    current_range = Factory.tstz_range(DateTime.add(now, -3_600))

    current =
      insert_legal_version!(
        document_kind: "consent_notice",
        audience: "consumer",
        locale: "pt-BR",
        effective_during: current_range
      )

    english =
      insert_legal_version!(
        document_kind: "consent_notice",
        audience: "consumer",
        locale: "en-US",
        effective_during: current_range
      )

    _future =
      insert_legal_version!(
        document_kind: "consent_notice",
        audience: "consumer",
        locale: "pt-BR",
        effective_during: Factory.tstz_range(DateTime.add(now, 3_600))
      )

    _expired =
      insert_legal_version!(
        document_kind: "consent_notice",
        audience: "consumer",
        locale: "pt-BR",
        effective_during: Factory.tstz_range(DateTime.add(now, -7_200), DateTime.add(now, -3_600))
      )

    other_document =
      insert_legal_version!(
        document_kind: "privacy_notice",
        audience: "consumer",
        locale: "pt-BR",
        effective_during: current_range
      )

    _retired =
      insert_legal_version!(
        document_kind: "consent_notice",
        audience: "consumer",
        document_status: "retired",
        locale: "pt-BR",
        effective_during: current_range
      )

    officer = Factory.insert(:user)
    PrivacyFixtures.privacy_officer!(officer)
    scope = ActorScope.new!(officer.id, Ecto.UUID.generate(version: 7))

    assert {:ok, [%{id: current_id}]} =
             Privacy.list_processing_purpose_legal_versions(scope, %{
               "locale" => "pt-BR",
               "legal_basis" => "consent"
             })

    assert current_id == current.version.id

    assert {:ok, [%{id: english_id}]} =
             Privacy.list_processing_purpose_legal_versions(scope, %{
               "locale" => "en-US",
               "legal_basis" => "consent"
             })

    assert english_id == english.version.id

    assert {:ok, contract_versions} =
             Privacy.list_processing_purpose_legal_versions(scope, %{
               "locale" => "pt-BR",
               "legal_basis" => "contract"
             })

    assert MapSet.new(Enum.map(contract_versions, & &1.id)) ==
             MapSet.new([current.version.id, other_document.version.id])
  end

  test "legal-version options reauthorize the actor and reject malformed filters" do
    user = Factory.insert(:user)
    scope = ActorScope.new!(user.id, Ecto.UUID.generate(version: 7))

    assert {:error, :platform_privacy_officer_required} =
             Privacy.list_processing_purpose_legal_versions(scope, %{})

    assert {:error, :invalid_actor_scope} =
             Privacy.list_processing_purpose_legal_versions(nil, %{})

    assert {:error, :invalid_locale} =
             Privacy.list_processing_purpose_legal_versions(scope, :invalid)

    assert {:error, :invalid_locale} =
             Privacy.list_processing_purpose_legal_versions(scope, %{"locale" => "pt BR"})

    assert {:error, :invalid_locale} =
             Privacy.list_processing_purpose_legal_versions(scope, %{"locale" => <<255>>})

    assert {:error, :invalid_processing_purpose} =
             Privacy.list_processing_purpose_legal_versions(scope, %{
               "legal_basis" => "invented"
             })
  end

  defp insert_legal_version!(options) do
    now = DateTime.utc_now(:microsecond)

    document =
      Factory.insert(:legal_document,
        code: "privacy-#{Ecto.UUID.generate(version: 7)}",
        document_kind: Keyword.fetch!(options, :document_kind),
        audience: Keyword.fetch!(options, :audience),
        status: Keyword.get(options, :document_status, "active")
      )

    version =
      Factory.insert(:legal_document_version,
        legal_document_id: document.id,
        version: Keyword.get(options, :version, 1),
        locale: Keyword.fetch!(options, :locale),
        content_uri: "/legal/#{document.code}.html",
        content_sha256: :crypto.hash(:sha256, document.code),
        effective_during: Keyword.fetch!(options, :effective_during),
        published_at: Keyword.get(options, :published_at, DateTime.add(now, -60)),
        inserted_at: now
      )

    %{document: document, version: version}
  end
end
