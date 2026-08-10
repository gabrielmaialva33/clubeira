defmodule ClubeiraWeb.System.ApiDocsController do
  use ClubeiraWeb, :controller

  @api_docs_path Path.expand("../../../../priv/static/api-docs/index.html", __DIR__)
  @external_resource @api_docs_path
  @api_docs_html File.read!(@api_docs_path)

  @content_security_policy "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; " <>
                             "script-src https://cdn.redocly.com; " <>
                             "style-src 'unsafe-inline' https://fonts.googleapis.com; " <>
                             "font-src data: https://fonts.gstatic.com; img-src data: https:; " <>
                             "connect-src 'self'"

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html", "utf-8")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_header("content-security-policy", @content_security_policy)
    |> put_resp_header("referrer-policy", "no-referrer")
    |> send_resp(200, @api_docs_html)
  end
end
