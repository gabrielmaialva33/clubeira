defmodule ClubeiraWeb.Public.LegalLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Legal

  @impl true
  def mount(_params, _session, socket) do
    legal_locale = legal_locale(socket.assigns.locale)

    case Legal.list_registration_documents(%{"locale" => legal_locale}) do
      {:ok, documents} ->
        public_documents =
          Enum.map(documents, &Map.put(&1, :public_uri, safe_content_uri(&1.content_uri)))

        {:ok,
         socket
         |> stream_configure(:documents, dom_id: &"public-legal-#{public_key(&1.code)}")
         |> assign(:page_title, gettext("Clubeira terms"))
         |> assign(:locale, legal_locale)
         |> stream(:documents, public_documents)}

      {:error, reason} ->
        Logger.error("could not load public legal documents for #{inspect(legal_locale)}",
          reason: inspect(reason)
        )

        {:ok,
         socket
         |> put_flash(:error, gettext("The legal documents are temporarily unavailable."))
         |> redirect(to: ~p"/explorar")}
    end
  end

  def document_label(%{document_kind: "terms_of_service"}), do: gettext("Terms of service")
  def document_label(%{document_kind: "privacy_notice"}), do: gettext("Privacy notice")
  def document_label(_document), do: gettext("Legal document")

  defp legal_locale("pt_BR"), do: "pt-BR"
  defp legal_locale(locale), do: String.replace(locale, "_", "-")

  defp safe_content_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: nil, host: nil, path: "/legal/" <> rest} when rest != "" -> uri
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> uri
      _invalid -> nil
    end
  end

  defp safe_content_uri(_uri), do: nil

  defp public_key(code) do
    :sha256
    |> :crypto.hash(code)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
