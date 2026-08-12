defmodule ClubeiraWeb.Backoffice.OperationsOutboxLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Operations
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @page_limit "20"
  @query_fields ~w(after limit status topic)
  @retry_fields ~w(idempotency_key)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:messages, dom_id: &"outbox-message-#{&1.id}")
     |> assign(:page_title, gettext("Outbox operations"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    polo = select_polo(socket.assigns.backoffice_access.polos, params["polo"])

    if :manage_operations in polo.capabilities do
      load_messages(socket, polo, params)
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

    {:noreply, push_patch(socket, to: outbox_path(polo.slug, "dead_letter"))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo could not be changed."))}
  end

  def handle_event(
        "retry_outbox_message",
        %{"message_id" => message_id, "retry" => params},
        socket
      )
      when is_binary(message_id) and is_map(params) do
    if Map.has_key?(socket.assigns.retry_forms, message_id) do
      case Accounts.refresh_scope(socket.assigns.current_account_scope) do
        {:ok, account_scope} ->
          socket
          |> assign(:current_account_scope, account_scope)
          |> retry_message(message_id, params)

        :error ->
          redirect_expired_session(socket)
      end
    else
      invalid_retry(socket)
    end
  end

  def handle_event("retry_outbox_message", _params, socket), do: invalid_retry(socket)

  defp invalid_retry(socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The outbox retry was invalid and was not processed."))}
  end

  defp load_messages(socket, polo, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, polo)

    query_params =
      params
      |> Map.take(@query_fields)
      |> Map.put_new("limit", @page_limit)

    case Operations.list_backoffice_outbox_messages(scope, query_params) do
      {:ok, result} ->
        {:noreply, assign_message_result(socket, polo, query_params, result)}

      {:error, :operations_admin_required} ->
        redirect_unauthorized(socket, polo)

      {:error, reason} ->
        Logger.error("could not load outbox operations queue",
          polo_id: polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The outbox operations queue is temporarily unavailable."))
         |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
    end
  end

  defp retry_message(socket, message_id, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    attributes = Map.take(params, @retry_fields)

    case Operations.retry_outbox_message(scope, message_id, attributes) do
      {:ok, _message} ->
        refresh_after_retry(socket, gettext("The outbox message was requeued successfully."))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :retry_forms,
           Map.put(socket.assigns.retry_forms, message_id, to_form(changeset, as: :retry))
         )
         |> put_flash(:error, gettext("The retry request was invalid."))}

      {:error, reason}
      when reason in [
             :outbox_message_not_found,
             :outbox_message_not_retryable,
             :idempotency_conflict
           ] ->
        refresh_after_retry(
          socket,
          gettext("The outbox message changed before the retry was completed."),
          :error
        )

      {:error, :operations_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not retry outbox message from backoffice",
          polo_id: socket.assigns.current_polo.id,
          message_id: message_id,
          reason: inspect(reason)
        )

        {:noreply,
         put_flash(socket, :error, gettext("The outbox message could not be requeued."))}
    end
  end

  defp refresh_after_retry(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)

    case Operations.list_backoffice_outbox_messages(scope, socket.assigns.query_params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign_message_result(
           socket.assigns.current_polo,
           socket.assigns.query_params,
           result
         )
         |> put_flash(flash_kind, message)}

      {:error, :operations_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload outbox operations queue",
          polo_id: socket.assigns.current_polo.id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated outbox queue could not be reloaded."))
         |> redirect(to: outbox_path(socket.assigns.current_polo.slug, "dead_letter"))}
    end
  end

  defp assign_message_result(socket, polo, query_params, result) do
    retry_forms =
      result.messages
      |> Enum.filter(&(&1.status == "dead_letter"))
      |> Map.new(&{&1.id, retry_form()})

    socket
    |> assign(:current_polo, polo)
    |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
    |> assign(:query_params, query_params)
    |> assign(:retry_forms, retry_forms)
    |> assign(:page, result.page)
    |> stream(:messages, result.messages, reset: true)
  end

  defp retry_form do
    %{"idempotency_key" => "outbox-retry-#{uuid7()}"}
    |> Operations.change_outbox_retry_request()
    |> to_form(as: :retry)
  end

  defp select_polo(polos, slug), do: Enum.find(polos, &(&1.slug == slug)) || List.first(polos)

  defp tenant_scope(account_scope, polo) do
    Scope.new!(polo.id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id,
      roles: polo.roles
    )
  end

  defp outbox_path(polo_slug, status) do
    ~p"/admin/operations/outbox?#{[polo: polo_slug, status: status]}"
  end

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to operations."))
     |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp redirect_expired_session(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your session has expired. Sign in again to continue."))
     |> redirect(to: ~p"/admin/login")}
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)

  defp timestamp(nil, _locale), do: gettext("Not available")

  defp timestamp(%DateTime{} = datetime, "pt_BR"),
    do: format_timestamp(datetime, "%d/%m/%Y · %H:%M")

  defp timestamp(%DateTime{} = datetime, "en"),
    do: format_timestamp(datetime, "%Y-%m-%d · %H:%M")

  defp format_timestamp(datetime, format) do
    "#{Calendar.strftime(datetime, format)} #{datetime.zone_abbr}"
  end

  defp status_label("pending"), do: gettext("Pending")
  defp status_label("publishing"), do: gettext("Publishing")
  defp status_label("published"), do: gettext("Published")
  defp status_label("dead_letter"), do: gettext("Dead letter")

  defp status_class("published"), do: "bg-emerald-50 text-emerald-700 ring-emerald-600/10"
  defp status_class("dead_letter"), do: "bg-red-50 text-red-700 ring-red-600/10"
  defp status_class("publishing"), do: "bg-blue-50 text-blue-700 ring-blue-600/10"
  defp status_class(_status), do: "bg-amber-50 text-amber-700 ring-amber-600/10"
end
