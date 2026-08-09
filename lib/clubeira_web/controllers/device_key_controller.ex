defmodule ClubeiraWeb.DeviceKeyController do
  use ClubeiraWeb, :controller

  alias Clubeira.Devices
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def show(conn, %{"device_id" => device_id}) do
    case Devices.get_current_device_key(conn.assigns.current_account_scope, device_id) do
      {:ok, key} -> render(conn, :show, key: key)
      {:error, :device_key_not_found} -> render_error(conn, :not_found)
    end
  end

  def update(conn, %{"device_id" => device_id} = params) do
    attributes = Map.take(params, ~w(installation_token public_key proof))

    case Devices.put_device_key(conn.assigns.current_account_scope, device_id, attributes) do
      {:ok, result} ->
        conn
        |> put_status(if(result.created?, do: :created, else: :ok))
        |> render(:show, key: result.key)

      {:error, :device_key_not_found} ->
        render_error(conn, :not_found)

      {:error, :device_key_conflict} ->
        render_error(conn, :conflict, "device_key_conflict")

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)
    end
  end

  defp render_error(conn, status, code \\ nil) do
    assigns = if code, do: %{code: code}, else: %{}

    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", assigns))
  end
end
