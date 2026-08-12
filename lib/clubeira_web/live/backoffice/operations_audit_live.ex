defmodule ClubeiraWeb.Backoffice.OperationsAuditLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Operations
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(action after limit resource_type)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:events, dom_id: &"audit-event-#{&1.id}")
     |> assign(:page_title, gettext("Audit trail"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    polo = select_polo(socket.assigns.backoffice_access.polos, params["polo"])

    if :manage_operations in polo.capabilities do
      load_events(socket, polo, params)
    else
      redirect_unauthorized(socket, polo)
    end
  end

  @impl true
  def handle_event("change_polo", %{"context" => %{"polo" => slug}}, socket)
      when is_binary(slug) do
    polo =
      Enum.find(socket.assigns.backoffice_access.polos, &(&1.slug == slug)) ||
        socket.assigns.current_polo

    {:noreply, push_patch(socket, to: audit_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  defp load_events(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)

    query_params =
      params
      |> Map.take(@query_fields)
      |> Map.put_new("limit", @page_limit)

    case Operations.list_backoffice_audit_events(scope, query_params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:current_polo, polo)
         |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
         |> assign(:page, result.page)
         |> stream(:events, result.events, reset: true)}

      {:error, :operations_admin_required} ->
        redirect_unauthorized(socket, polo)

      {:error, reason} ->
        Logger.error("could not load tenant audit trail",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The audit trail is temporarily unavailable."))
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
    end
  end

  defp select_polo(polos, slug), do: Enum.find(polos, &(&1.slug == slug)) || List.first(polos)

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp audit_path(polo_slug), do: ~p"/admin/operations/audit?#{[polo: polo_slug]}"

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to operations."))
     |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp timestamp(%DateTime{} = datetime, "pt_BR"),
    do: format_timestamp(datetime, "%d/%m/%Y · %H:%M")

  defp timestamp(%DateTime{} = datetime, "en"),
    do: format_timestamp(datetime, "%Y-%m-%d · %H:%M")

  defp format_timestamp(datetime, format) do
    "#{Calendar.strftime(datetime, format)} #{datetime.zone_abbr}"
  end

  defp humanized(value), do: value |> to_string() |> String.replace(~r/[_.]/, " ")
end
