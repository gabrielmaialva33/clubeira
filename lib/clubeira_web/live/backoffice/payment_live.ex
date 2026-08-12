defmodule ClubeiraWeb.Backoffice.PaymentLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Billing
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.BackofficeComponents

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

  defp load_payment(socket, polo, payment_id) do
    if :manage_billing in polo.capabilities do
      scope = tenant_scope(socket.assigns.current_account_scope, polo)

      case Billing.get_backoffice_payment(scope, payment_id) do
        {:ok, payment} ->
          {:noreply,
           socket
           |> assign(:current_polo, polo)
           |> assign(:polo_form, to_form(%{"polo" => polo.slug}, as: :context))
           |> assign(:payment, payment)}

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

  defp order_status_label("pending"), do: gettext("Pending")
  defp order_status_label("awaiting_payment"), do: gettext("Awaiting payment")
  defp order_status_label("paid"), do: gettext("Paid")
  defp order_status_label("cancelled"), do: gettext("Cancelled")
  defp order_status_label("expired"), do: gettext("Expired")
  defp order_status_label("refunded"), do: gettext("Refunded")
  defp order_status_label("charged_back"), do: gettext("Charged back")

  defp humanized(value), do: value |> to_string() |> String.replace("_", " ")
end
