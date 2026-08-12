defmodule ClubeiraWeb.Auth.BrowserAccountHTML do
  @moduledoc false

  use ClubeiraWeb, :html

  embed_templates "browser_account_html/*"

  def document_label(%{document_kind: "terms_of_service"}), do: gettext("Terms of service")
  def document_label(_document), do: gettext("Legal document")
end
