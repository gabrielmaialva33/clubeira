defmodule ClubeiraWeb.Backoffice.PlacesLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Directory
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(after limit profile_status status)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:places, dom_id: &"place-#{&1.id}")
     |> assign(:page_title, gettext("Places"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    polo = select_polo(socket.assigns.backoffice_access.polos, params["polo"])

    if :manage_partners in polo.capabilities do
      scope = tenant_scope(socket.assigns.current_account_scope, polo)

      query_params =
        params
        |> Map.take(@query_fields)
        |> Map.put_new("limit", @page_limit)

      case Directory.list_backoffice_places(scope, query_params) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:current_polo, polo)
           |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
           |> assign(
             :filter_form,
             to_form(
               %{
                 "status" => Map.get(params, "status", ""),
                 "profile_status" => Map.get(params, "profile_status", "")
               },
               as: :filters
             )
           )
           |> assign(:limit_param, Map.get(params, "limit"))
           |> assign(:next_page_path, next_page_path(polo, params, result.page))
           |> assign(:page, result.page)
           |> stream(:places, result.places, reset: true)}

        {:error, reason}
        when reason in [
               :invalid_pagination,
               :invalid_place_id,
               :invalid_place_profile_status,
               :invalid_place_status
             ] ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("The inventory filters were invalid and have been cleared.")
           )
           |> redirect(to: ~p"/admin/places?#{[polo: polo.slug]}")}

        {:error, :partner_admin_required} ->
          redirect_unauthorized(socket, polo)

        {:error, reason} ->
          Logger.error("could not load backoffice place inventory",
            polo_id: polo.id,
            reason: inspect(reason)
          )

          {:noreply,
           socket
           |> put_flash(:error, gettext("The place inventory is temporarily unavailable."))
           |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
      end
    else
      redirect_unauthorized(socket, polo)
    end
  end

  @impl true
  def handle_event("change_polo", %{"context" => %{"polo" => slug}}, socket) do
    polo =
      Enum.find(socket.assigns.backoffice_access.polos, &(&1.slug == slug)) ||
        socket.assigns.current_polo

    {:noreply, push_patch(socket, to: ~p"/admin/places?#{[polo: polo.slug]}")}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    query =
      [polo: socket.assigns.current_polo.slug]
      |> maybe_put_filter(:status, filters["status"])
      |> maybe_put_filter(:profile_status, filters["profile_status"])
      |> maybe_put_filter(:limit, socket.assigns.limit_param)

    {:noreply, push_patch(socket, to: ~p"/admin/places?#{query}")}
  end

  defp select_polo(polos, slug), do: Enum.find(polos, &(&1.slug == slug)) || List.first(polos)

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp maybe_put_filter(query, _key, value) when value in [nil, ""], do: query
  defp maybe_put_filter(query, key, value), do: query ++ [{key, value}]

  defp next_page_path(_polo, _params, %{has_more: false}), do: nil

  defp next_page_path(polo, params, page) do
    query =
      [polo: polo.slug]
      |> maybe_put_filter(:status, params["status"])
      |> maybe_put_filter(:profile_status, params["profile_status"])
      |> maybe_put_filter(:limit, params["limit"])
      |> maybe_put_filter(:after, page.next_cursor)

    ~p"/admin/places?#{query}"
  end

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to the place inventory."))
     |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp profile_label(nil), do: gettext("Missing profile")
  defp profile_label(_profile), do: gettext("Published profile")

  defp status_label("active"), do: gettext("Active")
  defp status_label("invited"), do: gettext("Invited")
  defp status_label("suspended"), do: gettext("Suspended")
  defp status_label("retired"), do: gettext("Retired")
end
