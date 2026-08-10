defmodule ClubeiraWeb.Member.RedemptionDeviceController do
  use ClubeiraWeb, :controller

  alias Clubeira.Devices
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @conflict_errors ~w(device_limit_reached device_unavailable installation_conflict)a

  def create(conn, %{"polo_slug" => polo_slug} = params) do
    case Devices.enroll_redemption_device(
           conn.assigns.current_account_scope,
           polo_slug,
           Map.take(params, ~w(access_contract_id installation_token platform))
         ) do
      {:ok, %{created?: created?} = enrollment} ->
        conn
        |> put_status(if(created?, do: :created, else: :ok))
        |> render(:create, enrollment: enrollment)

      {:error, reason} when reason in [:polo_not_found, :contract_not_found] ->
        render_error(conn, :not_found)

      {:error, reason} when reason in @conflict_errors ->
        render_error(conn, :conflict)

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)
    end
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
