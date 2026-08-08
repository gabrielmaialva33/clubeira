defmodule ClubeiraWeb.ReadinessController do
  use ClubeiraWeb, :controller

  alias Clubeira.Readiness

  def show(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Readiness.check() do
      :ok ->
        json(conn, %{service: "clubeira", status: "ready"})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{service: "clubeira", status: "not_ready"})
    end
  end
end
