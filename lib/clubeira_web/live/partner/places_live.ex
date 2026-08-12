defmodule ClubeiraWeb.Partner.PlacesLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Directory
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.PartnerComponents

  @page_limit "20"
  @query_fields ~w(after limit)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:places, dom_id: &"partner-place-#{&1.id}")
     |> assign(:page_title, gettext("My places"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case select_polo(socket.assigns.partner_access.polos, params["polo"]) do
      {:ok, polo} -> load_places(socket, polo, params)
      {:invalid, fallback} -> redirect_invalid_polo(socket, fallback)
    end
  end

  @impl true
  def handle_event("change_polo", %{"context" => %{"polo" => slug}}, socket) do
    polo =
      Enum.find(socket.assigns.partner_access.polos, &(&1.slug == slug)) ||
        socket.assigns.current_polo

    {:noreply, push_patch(socket, to: places_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo is invalid."))}
  end

  defp load_places(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)

    query_params =
      params
      |> Map.take(@query_fields)
      |> Map.put_new("limit", @page_limit)

    case Directory.list_partner_places(scope, query_params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:current_polo, polo)
         |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
         |> assign(:page, result.page)
         |> assign(:next_page_path, next_page_path(polo, params, result.page))
         |> stream(:places, result.places, reset: true)}

      {:error, :invalid_pagination} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The page cursor was invalid and has been cleared."))
         |> redirect(to: places_path(polo.slug))}

      {:error, :partner_access_required} ->
        redirect_unauthorized(socket)

      {:error, reason} ->
        Logger.error("could not load partner place inventory",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("Your places are temporarily unavailable."))
         |> redirect(to: places_path(polo.slug))}
    end
  end

  defp select_polo(polos, nil), do: {:ok, List.first(polos)}

  defp select_polo(polos, slug) do
    case Enum.find(polos, &(&1.slug == slug)) do
      nil -> {:invalid, List.first(polos)}
      polo -> {:ok, polo}
    end
  end

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp next_page_path(_polo, _params, %{has_more: false}), do: nil

  defp next_page_path(polo, params, page) do
    query =
      %{"polo" => polo.slug, "after" => page.next_cursor}
      |> maybe_put("limit", params["limit"])

    "/partner?#{URI.encode_query(query)}"
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp places_path(slug), do: "/partner?#{URI.encode_query(%{"polo" => slug})}"

  defp redirect_invalid_polo(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The selected polo is not available for this account."))
     |> redirect(to: places_path(polo.slug))}
  end

  defp redirect_unauthorized(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your partner access is no longer available."))
     |> redirect(to: "/partner/login")}
  end

  defp profile_label(nil), do: gettext("Missing profile")
  defp profile_label(_profile), do: gettext("Published profile")
end
