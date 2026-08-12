defmodule ClubeiraWeb.Backoffice.PaymentLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Billing
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

  @refund_command_fields ~w(idempotency_key reason)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Payment details"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case select_polo(socket.assigns.backoffice_access.polos, params["polo"]) do
      {:ok, polo} -> load_payment(socket, polo, params["payment_id"])
      {:invalid, fallback} -> redirect_invalid_polo(socket, fallback)
    end
  end

  @impl true
  def handle_event("change_polo", %{"context" => %{"polo" => slug}}, socket)
      when is_binary(slug) do
    polo =
      Enum.find(socket.assigns.backoffice_access.polos, &(&1.slug == slug)) ||
        socket.assigns.current_polo

    {:noreply, push_navigate(socket, to: finance_path(polo.slug))}
  end

  def handle_event("change_polo", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The selected polo is invalid."))}
  end

  def handle_event("refund_payment", %{"refund" => params}, socket) when is_map(params) do
    case refresh_account(socket) do
      {:ok, socket} -> process_refund_request(socket, params)
      :error -> redirect_expired_session(socket)
    end
  end

  def handle_event("refund_payment", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("The refund request was invalid and was not processed."))}
  end

  defp load_payment(socket, polo, payment_id) do
    if :manage_billing in polo.capabilities do
      scope = tenant_scope(socket.assigns.current_account_scope, polo)

      case Billing.get_backoffice_payment(scope, payment_id) do
        {:ok, payment} ->
          {:noreply,
           socket
           |> assign(:current_polo, polo)
           |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
           |> assign_payment(payment)}

        {:error, :payment_not_found} ->
          redirect_missing(socket, polo)

        {:error, :billing_admin_required} ->
          redirect_unauthorized(socket, polo)

        {:error, reason} ->
          Logger.error("could not load backoffice payment detail",
            polo_id: polo.id,
            payment_id: payment_id,
            reason: inspect(reason)
          )

          {:noreply,
           socket
           |> put_flash(:error, gettext("The payment details are temporarily unavailable."))
           |> redirect(to: finance_path(polo.slug))}
      end
    else
      redirect_unauthorized(socket, polo)
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

  defp refresh_account(socket) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} -> {:ok, assign(socket, :current_account_scope, account_scope)}
      :error -> :error
    end
  end

  defp process_refund_request(%{assigns: %{refund_form: nil}} = socket, _params) do
    {:noreply,
     put_flash(socket, :error, gettext("A refund is no longer available for this payment."))}
  end

  defp process_refund_request(socket, params) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    attributes = Map.take(params, @refund_command_fields)

    scope
    |> Billing.refund_payment(socket.assigns.payment.id, attributes)
    |> handle_refund_result(socket, params)
  end

  defp handle_refund_result({:ok, _refund}, socket, _params) do
    refresh_after_refund(socket, gettext("The payment was refunded successfully."))
  end

  defp handle_refund_result({:error, :payment_gateway_unavailable}, socket, params) do
    {:noreply,
     socket
     |> assign(:refund_form, form_from_params(params))
     |> put_flash(
       :error,
       gettext("The payment provider did not confirm the refund. Retry with the same values.")
     )}
  end

  defp handle_refund_result({:error, :idempotency_conflict}, socket, _params) do
    refresh_after_refund(
      socket,
      gettext(
        "This request changed after it started. Review the current state and submit again."
      ),
      :error
    )
  end

  defp handle_refund_result({:error, :payment_gateway_rejected}, socket, _params) do
    refresh_after_refund(
      socket,
      gettext("The payment provider rejected this attempt. Review it and submit a new request."),
      :error
    )
  end

  defp handle_refund_result({:error, %Ecto.Changeset{} = changeset}, socket, _params) do
    {:noreply,
     socket
     |> assign(:refund_form, to_form(changeset, as: :refund))
     |> put_flash(:error, gettext("Review the refund request before submitting."))}
  end

  defp handle_refund_result(
         {:error, reason},
         socket,
         _params
       )
       when reason in [
              :refund_unavailable,
              :refund_in_progress,
              :payment_already_refunded,
              :payment_not_refundable
            ] do
    refresh_after_refund(
      socket,
      gettext("A refund is no longer available for this payment."),
      :error
    )
  end

  defp handle_refund_result({:error, :payment_not_found}, socket, _params) do
    redirect_missing(socket, socket.assigns.current_polo)
  end

  defp handle_refund_result({:error, :billing_admin_required}, socket, _params) do
    redirect_unauthorized(socket, socket.assigns.current_polo)
  end

  defp handle_refund_result({:error, reason}, socket, params) do
    Logger.error("could not refund backoffice payment",
      polo_id: socket.assigns.current_polo.id,
      payment_id: socket.assigns.payment.id,
      reason: inspect(reason)
    )

    {:noreply,
     socket
     |> assign(:refund_form, form_from_params(params))
     |> put_flash(:error, gettext("The refund could not be completed."))}
  end

  defp refresh_after_refund(socket, message, flash_kind \\ :info) do
    scope = tenant_scope(socket.assigns.current_account_scope, socket.assigns.current_polo)
    payment_id = socket.assigns.payment.id

    case Billing.get_backoffice_payment(scope, payment_id) do
      {:ok, payment} ->
        {:noreply,
         socket
         |> assign_payment(payment)
         |> put_flash(flash_kind, message)}

      {:error, :payment_not_found} ->
        redirect_missing(socket, socket.assigns.current_polo)

      {:error, :billing_admin_required} ->
        redirect_unauthorized(socket, socket.assigns.current_polo)

      {:error, reason} ->
        Logger.error("could not reload backoffice payment after refund",
          polo_id: socket.assigns.current_polo.id,
          payment_id: payment_id,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> put_flash(:error, gettext("The updated payment could not be reloaded."))
         |> redirect(to: finance_path(socket.assigns.current_polo.slug))}
    end
  end

  defp assign_payment(socket, payment) do
    socket
    |> assign(:payment, payment)
    |> assign(:refund_form, refund_form(payment))
  end

  defp refund_form(%{status: "captured", refund: nil, chargeback: nil}) do
    new_refund_form()
  end

  defp refund_form(%{status: "captured", refund: %{status: "failed"}, chargeback: nil}) do
    new_refund_form()
  end

  defp refund_form(_payment), do: nil

  defp new_refund_form do
    to_form(
      Billing.change_refund_request(%{
        reason: "",
        idempotency_key: refund_idempotency_key()
      }),
      as: :refund
    )
  end

  defp form_from_params(params) do
    params
    |> Billing.change_refund_request()
    |> to_form(as: :refund)
  end

  defp refund_idempotency_key do
    "payment-refund-#{Ecto.UUID.generate(version: 7, precision: :monotonic)}"
  end

  defp finance_path(polo_slug), do: ~p"/admin?#{[polo: polo_slug]}" <> "#payments-section"

  defp redirect_invalid_polo(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The selected polo is not available for this account."))
     |> redirect(to: finance_path(polo.slug))}
  end

  defp redirect_missing(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("The payment was not found in this polo."))
     |> redirect(to: finance_path(polo.slug))}
  end

  defp redirect_unauthorized(socket, polo) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("You do not have access to manage payments."))
     |> redirect(to: ~p"/admin?#{[polo: polo.slug]}")}
  end

  defp redirect_expired_session(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your session has expired. Sign in again to continue."))
     |> redirect(to: ~p"/admin/login")}
  end

  defp money(amount, currency, locale) do
    normalized =
      amount
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)
      |> localize_decimal_separator(locale)

    "#{currency} #{normalized}"
  end

  defp localize_decimal_separator(value, "en"), do: value
  defp localize_decimal_separator(value, "pt_BR"), do: String.replace(value, ".", ",")

  defp timestamp(nil, _locale), do: gettext("Not available")

  defp timestamp(%DateTime{} = datetime, "pt_BR"),
    do: format_timestamp(datetime, "%d/%m/%Y · %H:%M")

  defp timestamp(%DateTime{} = datetime, "en"),
    do: format_timestamp(datetime, "%Y-%m-%d · %H:%M")

  defp format_timestamp(datetime, format) do
    "#{Calendar.strftime(datetime, format)} #{datetime.zone_abbr}"
  end

  defp status_label("authorized"), do: gettext("Authorized")
  defp status_label("captured"), do: gettext("Captured")
  defp status_label("failed"), do: gettext("Failed")
  defp status_label("cancelled"), do: gettext("Cancelled")
  defp status_label("refunded"), do: gettext("Refunded")
  defp status_label("charged_back"), do: gettext("Charged back")
  defp status_label("requested"), do: gettext("Requested")
  defp status_label("processing"), do: gettext("Processing")
  defp status_label("succeeded"), do: gettext("Succeeded")

  defp order_status_label("pending"), do: gettext("Pending")
  defp order_status_label("awaiting_payment"), do: gettext("Awaiting payment")
  defp order_status_label("paid"), do: gettext("Paid")
  defp order_status_label("cancelled"), do: gettext("Cancelled")
  defp order_status_label("expired"), do: gettext("Expired")
  defp order_status_label("refunded"), do: gettext("Refunded")
  defp order_status_label("charged_back"), do: gettext("Charged back")

  defp humanized(value), do: value |> to_string() |> String.replace("_", " ")
end
