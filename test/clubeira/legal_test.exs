defmodule Clubeira.LegalTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Legal
  alias Clubeira.LegalFixtures

  test "lists the current consumer terms required by registration" do
    terms = LegalFixtures.registration_terms!()

    assert {:ok,
            [
              %{
                id: version_id,
                code: code,
                document_kind: "terms_of_service",
                locale: "pt-BR",
                version: 1,
                content_uri: "/legal/demo-consumer-terms-v1.txt",
                content_sha256: content_sha256
              }
            ]} = Legal.list_registration_documents(%{"locale" => "pt-BR"})

    assert version_id == terms.version_id
    assert code =~ "consumer-terms-"
    assert byte_size(content_sha256) == 64
  end

  test "rejects an invalid registration locale" do
    assert Legal.list_registration_documents(%{"locale" => ""}) ==
             {:error, :invalid_locale}

    assert Legal.list_registration_documents(%{"locale" => String.duplicate("x", 36)}) ==
             {:error, :invalid_locale}
  end
end
