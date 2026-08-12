defmodule ClubeiraWeb.Backoffice.ModerationReviewsLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(after limit status)
  @moderation_fields ~w(action reason idempotency_key)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:reviews, dom_id: &"review-#{&1.id}")
     |> assign(:page_title, gettext("Review moderation"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    polo = select_polo(socket.assigns.backoffice_access.polos, params["polo"])

    if :moderate_reviews in polo.capabilities do
      load_reviews(socket, polo, params)
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

    {:noreply, push_patch(socket, to: reviews_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event(
        "moderate_review",
        %{"review_id" => review_id, "moderation" => params},
        socket
      )
      when is_binary(review_id) and is_map(params) do
    if Map.has_key?(socket.assigns.moderation_forms, review_id) do
      case Accounts.refresh_scope(socket.assigns.current_account_scope) do
        {:ok, account_scope} ->
          socket
          |> assign(:current_account_scope, account_scope)
          |> moderate_review(review_id, params)

        :error ->
          redirect_expired_session(socket)
      end
    else
      invalid_moderation(socket)
    end
  end

  def handle_event("moderate_review", _params, socket), do: invalid_moderation(socket)

  defp invalid_moderation(socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("The moderation request was invalid and was not processed.")
     )}
  end

  defp load_reviews(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)

    query_params =
      params
      |> Map.take(@query_fields)
      |> Map.put_new("limit", @page_limit)

    case Reviews.list_for_moderation(scope, query_params) do
      {:ok, result} ->
        {:noreply, assign_review_result(socket, polo, query_params, result)}

      {:error, :moderator_required} ->
        redirect_unauthorized(socket, polo)

      {:error, reason} ->
        Logger.error("could not load review moderation queue",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The review moderation queue is temporarily unavailable."))
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
    end
  end

  defp moderate_review(socket, review_id, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    attributes =
      params
      |> Map.take(@moderation_fields)
      |> Map.put("review_id", review_id)

    case Reviews.moderate(scope, attributes) do
      {:ok, _moderation} ->
        refresh_after_moderation(socket, gettext("The review was moderated successfully."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :moderation_forms,
           Map.put(
             socket.assigns.moderation_forms,
             review_id,
             to_form(changeset, as: :moderation)
           )
         )
         |> put_flash(:error, gettext("Review the moderation decision before submitting."))}

      {:error, reason}
      when reason in [:invalid_review_transition, :review_not_found, :idempotency_conflict] ->
        refresh_after_moderation(
          socket,
          gettext("The review changed before this decision was completed. Review the queue."),
          :error
        )

      {:error, :moderator_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not moderate review from backoffice",
          polo_id: socket.assigns.current_polo.id,
          review_id: review_id,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, gettext("The review could not be moderated."))}
    end
  end

  defp refresh_after_moderation(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Reviews.list_for_moderation(scope, socket.assigns.query_params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign_review_result(
           socket.assigns.current_polo,
           socket.assigns.query_params,
           result
         )
         |> put_flash(flash_kind, message)}

      {:error, :moderator_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload review moderation queue",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated moderation queue could not be reloaded."))
         |> redirect(to: reviews_path(socket.assigns.current_polo.slug))}
    end
  end

  defp assign_review_result(socket, polo, query_params, result) do
    forms = Map.new(result.reviews, &{&1.id, moderation_form(&1.id)})

    socket
    |> assign(:current_polo, polo)
    |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
    |> assign(:query_params, query_params)
    |> assign(:moderation_forms, forms)
    |> assign(:page, result.page)
    |> stream(:reviews, result.reviews, reset: true)
  end

  defp moderation_form(review_id) do
    %{
      "review_id" => review_id,
      "action" => "",
      "reason" => "",
      "idempotency_key" => "review-moderation-#{uuid7()}"
    }
    |> Reviews.change_moderation_request()
    |> to_form(as: :moderation)
  end

  defp select_polo(polos, slug), do: Enum.find(polos, &(&1.slug == slug)) || List.first(polos)

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp reviews_path(polo_slug), do: ~p"/admin/moderation/reviews?#{[polo: polo_slug]}"

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to moderate reviews."))
     |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp redirect_expired_session(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your session has expired. Sign in again to continue."))
     |> redirect(to: ~p"/admin/login")}
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)

  defp timestamp(%DateTime{} = datetime, "pt_BR"),
    do: format_timestamp(datetime, "%d/%m/%Y · %H:%M")

  defp timestamp(%DateTime{} = datetime, "en"),
    do: format_timestamp(datetime, "%Y-%m-%d · %H:%M")

  defp format_timestamp(datetime, format) do
    "#{Calendar.strftime(datetime, format)} #{datetime.zone_abbr}"
  end
end
