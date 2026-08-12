defmodule ClubeiraWeb.Public.LegalLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.LegalFixtures

  test "publishes the current localized consumer terms without exposing legal UUIDs or digests",
       %{
         conn: conn
       } do
    terms = LegalFixtures.registration_terms!()

    {:ok, view, html} = live(conn, "/termos")

    assert has_element?(view, "#public-legal")

    assert has_element?(
             view,
             "#public-legal-documents a[href='/legal/demo-consumer-terms-v1.txt']"
           )

    assert has_element?(
             view,
             "#public-legal-documents article[data-document-kind='terms_of_service']"
           )

    refute html =~ terms.document_id
    refute html =~ terms.version_id
    refute html =~ ~r/[a-f0-9]{64}/
  end
end
