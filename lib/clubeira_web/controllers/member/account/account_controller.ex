defmodule ClubeiraWeb.Member.AccountController do
  use ClubeiraWeb, :controller

  def show(conn, _params) do
    render(conn, :show, account_scope: conn.assigns.current_account_scope)
  end
end
