defmodule ClubeiraWeb.Member.PlaceReviewsLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Directory
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.MemberComponents
  alias ClubeiraWeb.PublicReviewKey

  @review_page_limit "20"
  @query_fields ~w(after limit)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:reviews, dom_id: &"member-review-#{&1.public_key}")
     |> assign(:page_title, gettext("Place reviews"))
     |> assign(:report_target, nil)
     |> assign(:report_form, nil)
     |> assign(:report_idempotency_key, nil)
     |> assign(:reported_review_keys, MapSet.new())}
  end

  @impl true
  def handle_params(
        %{"polo_slug" => polo_slug, "place_slug" => place_slug} = params,
        _uri,
        socket
      ) do
    with {:ok, %{polo: polo, place: place}} <-
           Directory.get_public_place(polo_slug, place_slug),
         {:ok, result, report_key, report_unavailable?} <-
           load_review_page(polo, place, params) do
      reviews =
        Enum.map(result.reviews, &Map.put(&1, :public_key, PublicReviewKey.from_id(&1.id)))

      review_index = Map.new(reviews, &{&1.public_key, &1})

      {report_target, report_form, report_idempotency_key} =
        report_state(report_key, review_index)

      {:noreply,
       socket
       |> assign(:page_title, gettext("Reviews of %{place}", place: place.name))
       |> assign(:polo, polo)
       |> assign(:place, place)
       |> assign(:review_index, review_index)
       |> assign(:next_page_path, next_page_path(polo, place, params, result.page))
       |> assign(:report_target, report_target)
       |> assign(:report_form, report_form)
       |> assign(:report_idempotency_key, report_idempotency_key)
       |> maybe_put_report_unavailable(report_unavailable?)
       |> stream(:reviews, reviews, reset: true)}
    else
      {:error, :invalid_pagination} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The review page was invalid and has been reset."))
         |> redirect(to: place_reviews_path(polo_slug, place_slug))}

      {:error, reason} when reason in [:place_not_found, :polo_not_found] ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This place is not available."))
         |> redirect(to: ~p"/app/catalog")}

      {:error, reason} ->
        Logger.error("could not load member place reviews", reason: inspect(reason))

        {:noreply,
         socket
         |> put_flash(:error, gettext("The reviews are temporarily unavailable."))
         |> redirect(to: ~p"/app/catalog")}
    end
  end

  @impl true
  def handle_event("report_review", %{"review-key" => review_key}, socket)
      when is_binary(review_key) do
    case Map.fetch(socket.assigns.review_index, review_key) do
      {:ok, review} ->
        {:noreply,
         socket
         |> assign(:report_target, review)
         |> assign(:report_form, to_form(Reviews.change_review_report_request(%{})))
         |> assign(:report_idempotency_key, "report-#{uuid7()}")}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("This review is not available."))}
    end
  end

  def handle_event("report_review", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The report request was invalid."))}
  end

  def handle_event("validate_report", %{"review_report_request" => params}, socket)
      when is_map(params) do
    changeset =
      params
      |> report_attributes(socket)
      |> Reviews.change_review_report_request()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :report_form, to_form(changeset))}
  end

  def handle_event("validate_report", _params, socket), do: {:noreply, socket}

  def handle_event("submit_report", %{"review_report_request" => params}, socket)
      when is_map(params) do
    with %{public_key: review_key} <- socket.assigns.report_target,
         {:ok, account_scope} <- Accounts.refresh_scope(socket.assigns.current_account_scope),
         {:ok, _report} <-
           Reviews.report(
             tenant_scope(account_scope, socket.assigns.polo),
             report_attributes(params, socket)
           ) do
      {:noreply,
       socket
       |> assign(:current_account_scope, account_scope)
       |> mark_review_reported(review_key)
       |> clear_report()
       |> put_flash(:info, gettext("Report submitted for moderation."))}
    else
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Choose a review before reporting."))}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Your session has expired. Sign in again."))
         |> redirect(to: ~p"/app/login")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :report_form, to_form(changeset))}

      {:error, :review_already_reported} ->
        {:noreply, mark_as_reported(socket)}

      {:error, :review_report_not_allowed} ->
        {:noreply,
         socket
         |> clear_report()
         |> put_flash(:error, gettext("You cannot report your own review."))}

      {:error, reason} ->
        Logger.warning("could not submit member review report", reason: inspect(reason))

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The report could not be submitted. Please try again.")
         )}
    end
  end

  def handle_event("submit_report", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The report request was invalid."))}
  end

  def handle_event("cancel_report", _params, socket), do: {:noreply, clear_report(socket)}

  def reported?(reported_review_keys, review_key),
    do: MapSet.member?(reported_review_keys, review_key)

  defp mark_as_reported(socket) do
    review_key = socket.assigns.report_target.public_key

    socket
    |> mark_review_reported(review_key)
    |> clear_report()
    |> put_flash(:info, gettext("You already reported this review."))
  end

  defp mark_review_reported(socket, review_key) do
    review = Map.fetch!(socket.assigns.review_index, review_key)

    socket
    |> assign(:reported_review_keys, MapSet.put(socket.assigns.reported_review_keys, review_key))
    |> stream_insert(:reviews, review)
  end

  defp clear_report(socket) do
    socket
    |> assign(:report_target, nil)
    |> assign(:report_form, nil)
    |> assign(:report_idempotency_key, nil)
  end

  defp report_attributes(params, socket) do
    target = socket.assigns.report_target

    params
    |> Map.take(~w(reason_code details))
    |> Map.put("place_id", target && target.place_id)
    |> Map.put("review_id", target && target.id)
    |> Map.put("idempotency_key", socket.assigns.report_idempotency_key)
  end

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp report_state(%{dom_key: report_key}, review_index) do
    case Map.fetch(review_index, report_key) do
      {:ok, review} ->
        {review, to_form(Reviews.change_review_report_request(%{})), "report-#{uuid7()}"}

      :error ->
        {nil, nil, nil}
    end
  end

  defp report_state(_report_key, _review_index), do: {nil, nil, nil}

  defp load_review_page(polo, place, params) do
    with {:ok, result} <-
           Reviews.list_public(Scope.new!(polo.id), place.place_id, review_params(params)),
         {:ok, target, report_key, report_unavailable?} <-
           load_report_target(polo, place, params["report"]) do
      reviews = maybe_prepend_target(result.reviews, target)
      {:ok, %{result | reviews: reviews}, report_key, report_unavailable?}
    end
  end

  defp load_report_target(_polo, _place, nil), do: {:ok, nil, nil, false}

  defp load_report_target(polo, place, report_key) do
    with {:ok, review_id} <- PublicReviewKey.resolve(report_key),
         {:ok, review} <- Reviews.get_public(Scope.new!(polo.id), place.place_id, review_id) do
      {:ok, review, %{dom_key: PublicReviewKey.from_id(review.id)}, false}
    else
      {:error, reason} when reason in [:invalid_review_key, :review_not_found] ->
        {:ok, nil, nil, true}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_prepend_target(reviews, nil), do: reviews

  defp maybe_prepend_target(reviews, target) do
    if Enum.any?(reviews, &(&1.id == target.id)), do: reviews, else: [target | reviews]
  end

  defp maybe_put_report_unavailable(socket, true),
    do: put_flash(socket, :error, gettext("This review is not available."))

  defp maybe_put_report_unavailable(socket, false), do: socket

  defp review_params(params) do
    params
    |> Map.take(@query_fields)
    |> Map.put_new("limit", @review_page_limit)
  end

  defp next_page_path(_polo, _place, _params, %{has_more: false}), do: nil

  defp next_page_path(polo, place, params, page) do
    query =
      [after: page.next_cursor]
      |> maybe_put(:limit, params["limit"])

    place_reviews_path(polo.slug, place.slug, query)
  end

  defp place_reviews_path(polo_slug, place_slug, query \\ []) do
    ~p"/app/catalog/#{polo_slug}/places/#{place_slug}/reviews?#{query}"
  end

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: query ++ [{key, value}]

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
