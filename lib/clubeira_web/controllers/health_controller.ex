defmodule ClubeiraWeb.HealthController do
  use ClubeiraWeb, :controller

  def show(conn, _params) do
    json(conn, %{service: "clubeira", status: "ok"})
  end
end
