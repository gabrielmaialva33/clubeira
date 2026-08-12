defmodule ClubeiraWeb.PageController do
  use ClubeiraWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/explorar")
  end
end
