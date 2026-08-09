defmodule ClubeiraWeb.ProfileController do
  use ClubeiraWeb, :controller

  alias Clubeira.People
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def show(conn, _params) do
    case People.get_self_profile(actor_scope(conn)) do
      {:ok, profile} -> render(conn, :show, profile: profile)
      {:error, :profile_not_found} -> render_error(conn, :not_found)
    end
  end

  def update(conn, params) do
    case People.put_self_profile(actor_scope(conn), profile_attributes(params)) do
      {:ok, profile} ->
        render(conn, :update, profile: profile)

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} when reason in [:identifier_conflict, :contact_conflict] ->
        render_error(conn, :conflict, "profile_conflict")
    end
  end

  defp actor_scope(conn) do
    account_scope = conn.assigns.current_account_scope
    ActorScope.new!(account_scope.user.id, account_scope.request_id)
  end

  defp profile_attributes(params) do
    Map.take(params, ~w(display_name birth_date cpf phone))
  end

  defp render_error(conn, status, code \\ nil) do
    assigns = if code, do: %{code: code}, else: %{}

    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", assigns))
  end
end
