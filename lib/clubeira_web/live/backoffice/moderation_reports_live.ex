defmodule ClubeiraWeb.Backoffice.ModerationReportsLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Reviews
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(after limit status)
  @resolution_fields ~w(action reason idempotency_key)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:reports, dom_id: &"report-#{&1.id}")
     |> assign(:page_title, gettext("Review reports"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    polo = select_polo(socket.assigns.backoffice_access.polos, params["polo"])

    if :moderate_reviews in polo.capabilities do
      load_reports(socket, polo, params)
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

    {:noreply, push_patch(socket, to: reports_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event(
        "resolve_report",
        %{"report_id" => report_id, "resolution" => params},
        socket
      )
      when is_binary(report_id) and is_map(params) do
    if Map.has_key?(socket.assigns.resolution_forms, report_id) do
      case Accounts.refresh_scope(socket.assigns.current_account_scope) do
        {:ok, account_scope} ->
          socket
          |> assign(:current_account_scope, account_scope)
          |> resolve_report(report_id, params)

        :error ->
          redirect_expired_session(socket)
      end
    else
      invalid_resolution(socket)
    end
  end

  def handle_event("resolve_report", _params, socket), do: invalid_resolution(socket)

  defp invalid_resolution(socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("The report resolution was invalid and was not processed.")
     )}
  end

  defp load_reports(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)

    query_params =
      params
      |> Map.take(@query_fields)
      |> Map.put_new("limit", @page_limit)

    case Reviews.list_reports(scope, query_params) do
      {:ok, result} ->
        {:noreply, assign_report_result(socket, polo, query_params, result)}

      {:error, :moderator_required} ->
        redirect_unauthorized(socket, polo)

      {:error, reason} ->
        Logger.error("could not load review report queue",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The review report queue is temporarily unavailable."))
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
    end
  end

  defp resolve_report(socket, report_id, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    attributes =
      params
      |> Map.take(@resolution_fields)
      |> Map.put("review_report_id", report_id)

    case Reviews.resolve_report(scope, attributes) do
      {:ok, _resolution} ->
        refresh_after_resolution(socket, gettext("The report was resolved successfully."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :resolution_forms,
           Map.put(
             socket.assigns.resolution_forms,
             report_id,
             to_form(changeset, as: :resolution)
           )
         )
         |> put_flash(:error, gettext("Review the report resolution before submitting."))}

      {:error, reason}
      when reason in [
             :invalid_review_report_transition,
             :review_report_not_found,
             :idempotency_conflict
           ] ->
        refresh_after_resolution(
          socket,
          gettext("The report changed before this decision was completed. Review the queue."),
          :error
        )

      {:error, :moderator_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not resolve report from backoffice",
          polo_id: socket.assigns.current_polo.id,
          report_id: report_id,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, gettext("The report could not be resolved."))}
    end
  end

  defp refresh_after_resolution(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Reviews.list_reports(scope, socket.assigns.query_params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign_report_result(
           socket.assigns.current_polo,
           socket.assigns.query_params,
           result
         )
         |> put_flash(flash_kind, message)}

      {:error, :moderator_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload review report queue",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated report queue could not be reloaded."))
         |> redirect(to: reports_path(socket.assigns.current_polo.slug))}
    end
  end

  defp assign_report_result(socket, polo, query_params, result) do
    forms = Map.new(result.reports, &{&1.id, resolution_form(&1.id)})

    socket
    |> assign(:current_polo, polo)
    |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
    |> assign(:query_params, query_params)
    |> assign(:resolution_forms, forms)
    |> assign(:page, result.page)
    |> stream(:reports, result.reports, reset: true)
  end

  defp resolution_form(report_id) do
    %{
      "review_report_id" => report_id,
      "action" => "",
      "reason" => "",
      "idempotency_key" => "report-resolution-#{uuid7()}"
    }
    |> Reviews.change_review_report_resolution_request()
    |> to_form(as: :resolution)
  end

  defp select_polo(polos, slug), do: Enum.find(polos, &(&1.slug == slug)) || List.first(polos)

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp reports_path(polo_slug), do: ~p"/admin/moderation/reports?#{[polo: polo_slug]}"

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to moderate review reports."))
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

  defp humanized(value), do: value |> to_string() |> String.replace("_", " ")
end
