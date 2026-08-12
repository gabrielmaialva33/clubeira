defmodule ClubeiraWeb.Partner.ReviewsLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Directory
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.PartnerAuth
  alias ClubeiraWeb.PartnerComponents

  @page_limit "20"
  @query_fields ~w(after limit place_id)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:reviews, dom_id: &"partner-review-#{&1.id}")
     |> assign(:page_title, gettext("Review inbox"))
     |> assign(:selected_review, nil)
     |> assign(:response_form, nil)
     |> assign(:response_idempotency_key, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case select_polo(socket.assigns.partner_access.polos, params["polo"]) do
      {:ok, polo} -> load_reviews(socket, polo, params)
      {:invalid, fallback} -> redirect_invalid_polo(socket, fallback)
    end
  end

  @impl true
  def handle_event("change_polo", %{"context" => %{"polo" => slug}}, socket) do
    polo =
      Enum.find(socket.assigns.partner_access.polos, &(&1.slug == slug)) ||
        socket.assigns.current_polo

    {:noreply, push_patch(socket, to: reviews_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo is invalid."))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) when is_map(filters) do
    query =
      %{"polo" => socket.assigns.current_polo.slug}
      |> maybe_put("place_id", filters["place_id"])
      |> maybe_put("limit", socket.assigns.limit_param)

    {:noreply, push_patch(socket, to: "/partner/reviews?#{URI.encode_query(query)}")}
  end

  def handle_event("filter", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The review filter was invalid."))}
  end

  def handle_event("edit_response", %{"review_id" => review_id}, socket)
      when is_binary(review_id) do
    with {:ok, socket} <- refresh_partner(socket),
         {:ok, review} <- get_review(socket, review_id) do
      {:noreply, assign_response_editor(socket, review)}
    else
      :error -> redirect_unauthorized(socket)
      {:error, :review_not_found} -> response_not_found(socket)
      {:error, :partner_access_required} -> redirect_unauthorized(socket)
      {:error, reason} -> response_read_error(socket, reason)
    end
  end

  def handle_event("edit_response", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected review was invalid."))}
  end

  def handle_event("cancel_response", _params, socket) do
    {:noreply, clear_response_editor(socket)}
  end

  def handle_event("validate_response", %{"response" => params}, socket)
      when is_map(params) do
    if socket.assigns.selected_review do
      {:noreply, assign_response_form(socket, params, :validate)}
    else
      {:noreply, put_flash(socket, :error, gettext("Select a review before responding."))}
    end
  end

  def handle_event("validate_response", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The response form was invalid."))}
  end

  def handle_event("save_response", %{"response" => params}, socket) when is_map(params) do
    if socket.assigns.selected_review do
      case refresh_partner(socket) do
        {:ok, socket} -> process_response(socket, params)
        :error -> redirect_unauthorized(socket)
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Select a review before responding."))}
    end
  end

  def handle_event("save_response", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The response request was invalid."))}
  end

  defp load_reviews(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)

    query_params =
      params
      |> Map.take(@query_fields)
      |> Map.put_new("limit", @page_limit)

    with {:ok, result} <- Reviews.list_partner_reviews(scope, query_params),
         {:ok, places} <- Directory.list_partner_places(scope, %{"limit" => "100"}) do
      {:noreply,
       socket
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
       |> assign(:filter_form, filter_form(params))
       |> assign(:place_options, place_options(places.places))
       |> assign(:limit_param, params["limit"])
       |> assign(:next_page_path, next_page_path(polo, params, result.page))
       |> assign(:page, result.page)
       |> clear_response_editor()
       |> stream(:reviews, result.reviews, reset: true)}
    else
      {:error, :invalid_pagination} ->
        canonicalize_reviews(
          socket,
          polo,
          gettext("The page cursor was invalid and has been cleared.")
        )

      {:error, :place_not_found} ->
        canonicalize_reviews(socket, polo, gettext("The selected place is not available."))

      {:error, :partner_access_required} ->
        redirect_unauthorized(socket)

      {:error, reason} ->
        Logger.error("could not load partner review inbox",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The review inbox is temporarily unavailable."))
         |> redirect(to: reviews_path(polo.slug))}
    end
  end

  defp process_response(socket, params) do
    changeset = response_changeset(socket, params)

    case Ecto.Changeset.apply_action(changeset, :put_partner_response) do
      {:ok, request} ->
        put_response(socket, request, changeset)

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:response_form, to_form(changeset, as: :response))
         |> put_flash(:error, gettext("Review the response before publishing."))}
    end
  end

  defp put_response(socket, request, changeset) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    review_id = socket.assigns.selected_review.id

    scope
    |> Reviews.put_partner_response(review_id, %{
      "body" => request.body,
      "idempotency_key" => request.idempotency_key
    })
    |> handle_response_result(socket, changeset)
  end

  defp handle_response_result({:ok, _response}, socket, _changeset) do
    case get_review(socket, socket.assigns.selected_review.id) do
      {:ok, review} ->
        {:noreply,
         socket
         |> stream_insert(:reviews, review)
         |> clear_response_editor()
         |> put_flash(:info, gettext("The response was published successfully."))}

      {:error, :review_not_found} ->
        response_not_found(socket)

      {:error, :partner_access_required} ->
        redirect_unauthorized(socket)

      {:error, reason} ->
        response_read_error(socket, reason)
    end
  end

  defp handle_response_result({:error, :request_in_progress}, socket, changeset) do
    {:noreply,
     socket
     |> assign(:response_form, to_form(changeset, as: :response))
     |> put_flash(:error, gettext("This response is still being processed."))}
  end

  defp handle_response_result({:error, :idempotency_conflict}, socket, _changeset) do
    {:noreply,
     socket
     |> assign_response_editor(socket.assigns.selected_review)
     |> put_flash(:error, gettext("This response changed after submission. Review and retry."))}
  end

  defp handle_response_result({:error, %Ecto.Changeset{} = changeset}, socket, _form_changeset) do
    {:noreply,
     socket
     |> assign(:response_form, to_form(changeset, as: :response))
     |> put_flash(:error, gettext("Review the response before publishing."))}
  end

  defp handle_response_result({:error, :review_not_found}, socket, _changeset) do
    response_not_found(socket)
  end

  defp handle_response_result({:error, reason}, socket, _changeset)
       when reason in [:partner_access_required, :partner_admin_required] do
    redirect_unauthorized(socket)
  end

  defp handle_response_result({:error, reason}, socket, _changeset)
       when reason in [:review_not_responseable, :invalid_review_response_transition] do
    {:noreply,
     socket
     |> clear_response_editor()
     |> put_flash(:error, gettext("This review can no longer receive a response."))}
  end

  defp handle_response_result({:error, reason}, socket, _changeset) do
    Logger.error("could not publish partner review response",
      polo_id: socket.assigns.current_polo.id,
      place_id: socket.assigns.selected_review.place.id,
      reason: inspect(reason)
    )

    {:noreply, put_flash(socket, :error, gettext("The response could not be published."))}
  end

  defp get_review(socket, review_id) do
    socket.assigns.current_account_scope
    |> tenant_scope(socket.assigns.current_polo)
    |> Reviews.get_partner_review(review_id)
  end

  defp assign_response_editor(socket, review) do
    idempotency_key = response_idempotency_key()

    socket
    |> assign(:selected_review, review)
    |> assign(:response_idempotency_key, idempotency_key)
    |> assign(
      :response_form,
      %{
        "body" => response_body(review.response),
        "idempotency_key" => idempotency_key
      }
      |> Reviews.change_partner_response_request()
      |> to_form(as: :response)
    )
  end

  defp assign_response_form(socket, params, action) do
    changeset = response_changeset(socket, params)
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset
    assign(socket, :response_form, to_form(changeset, as: :response))
  end

  defp response_changeset(socket, params) do
    params
    |> Map.take(["body"])
    |> Map.put("idempotency_key", socket.assigns.response_idempotency_key)
    |> Reviews.change_partner_response_request()
  end

  defp response_body(nil), do: ""
  defp response_body(response), do: response.body

  defp clear_response_editor(socket) do
    socket
    |> assign(:selected_review, nil)
    |> assign(:response_form, nil)
    |> assign(:response_idempotency_key, nil)
  end

  defp refresh_partner(socket) do
    with {:ok, account_scope} <- Accounts.refresh_scope(socket.assigns.current_account_scope),
         {:ok, partner_access} <- PartnerAuth.authorize(account_scope),
         %{} = polo <-
           Enum.find(partner_access.polos, &(&1.id == socket.assigns.current_polo.id)) do
      {:ok,
       socket
       |> assign(:current_account_scope, account_scope)
       |> assign(:partner_access, partner_access)
       |> assign(:current_polo, polo)
       |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))}
    else
      _invalid_or_revoked -> :error
    end
  end

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp select_polo(polos, nil), do: {:ok, List.first(polos)}

  defp select_polo(polos, slug) do
    case Enum.find(polos, &(&1.slug == slug)) do
      nil -> {:invalid, List.first(polos)}
      polo -> {:ok, polo}
    end
  end

  defp filter_form(params) do
    to_form(%{"place_id" => Map.get(params, "place_id", "")}, as: :filters)
  end

  defp place_options(places), do: Enum.map(places, &{&1.place.name, &1.place.id})

  defp next_page_path(_polo, _params, %{has_more: false}), do: nil

  defp next_page_path(polo, params, page) do
    query =
      %{"polo" => polo.slug, "after" => page.next_cursor}
      |> maybe_put("place_id", params["place_id"])
      |> maybe_put("limit", params["limit"])

    "/partner/reviews?#{URI.encode_query(query)}"
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reviews_path(slug), do: "/partner/reviews?#{URI.encode_query(%{"polo" => slug})}"

  defp response_idempotency_key do
    "partner-review-response-#{Ecto.UUID.generate(version: 7, precision: :monotonic)}"
  end

  defp canonicalize_reviews(socket, polo, message) do
    {:noreply,
     socket
     |> put_flash(:error, message)
     |> redirect(to: reviews_path(polo.slug))}
  end

  defp redirect_invalid_polo(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The selected polo is not available for this account."))
     |> redirect(to: reviews_path(polo.slug))}
  end

  defp redirect_unauthorized(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your partner access is no longer available."))
     |> redirect(to: "/partner/login")}
  end

  defp response_not_found(socket) do
    {:noreply,
     socket
     |> clear_response_editor()
     |> put_flash(:error, gettext("The review was not found in your current assignments."))}
  end

  defp response_read_error(socket, reason) do
    Logger.error("could not load exact partner review",
      polo_id: socket.assigns.current_polo.id,
      reason: inspect(reason)
    )

    {:noreply, put_flash(socket, :error, gettext("The review is temporarily unavailable."))}
  end
end
