defmodule ClubeiraWeb.PlatformBillingPlanController do
  use ClubeiraWeb, :controller

  alias Clubeira.PlatformBilling
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def index(conn, _params) do
    case PlatformBilling.list_plans(actor_scope(conn)) do
      {:ok, plans} -> render(conn, :index, plans: plans)
      {:error, reason} -> render_domain_error(conn, reason)
    end
  end

  def put_version(conn, %{"plan_code" => code, "version" => raw_version} = params) do
    with {:ok, version} <- positive_integer(raw_version),
         {:ok, plan} <-
           PlatformBilling.publish_plan(
             actor_scope(conn),
             code,
             version,
             Map.delete(params, "version")
           ) do
      render(conn, :show, plan: plan)
    else
      {:error, reason} -> render_domain_error(conn, reason)
    end
  end

  defp actor_scope(conn) do
    account_scope = conn.assigns.current_account_scope
    ActorScope.new!(account_scope.user.id, account_scope.request_id)
  end

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _invalid -> {:error, :invalid_platform_plan_identity}
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_platform_plan_identity}

  defp render_domain_error(conn, %Ecto.Changeset{}),
    do: render_error(conn, :unprocessable_entity)

  defp render_domain_error(conn, :platform_billing_admin_required),
    do: render_error(conn, :forbidden, "platform_billing_admin_required")

  defp render_domain_error(conn, reason)
       when reason in [:invalid_platform_plan_identity, :platform_feature_conflict],
       do: render_error(conn, :unprocessable_entity, Atom.to_string(reason))

  defp render_domain_error(conn, reason)
       when reason in [
              :platform_plan_retired,
              :platform_plan_version_conflict,
              :platform_plan_version_gap
            ],
       do: render_error(conn, :conflict, Atom.to_string(reason))

  defp render_domain_error(conn, _reason), do: render_error(conn, :unprocessable_entity)

  defp render_error(conn, status, code \\ nil) do
    assigns = if code, do: %{code: code}, else: %{}

    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", assigns))
  end
end
