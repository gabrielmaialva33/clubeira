defmodule ClubeiraWeb.PageController do
  use ClubeiraWeb, :controller

  def home(conn, _params) do
    render(conn, :home, page_title: "Foundation")
  end
end
