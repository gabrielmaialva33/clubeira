defmodule ClubeiraWeb.Member.PrivacyLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Privacy
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.MemberComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:consents, dom_id: &"member-consent-#{&1.processing_purpose.code}")
      |> stream_configure(:requests, dom_id: &"member-privacy-request-#{&1.id}")
      |> assign(:page_title, gettext("Privacy"))

    {:ok, load_privacy(socket)}
  end

  @impl true
  def handle_event(
        "put_consent",
        %{"purpose-code" => purpose_code, "state" => state},
        socket
      )
      when is_binary(purpose_code) and is_binary(state) do
    with {:ok, socket} <- refresh_session(socket),
         {:ok, consents} <- Privacy.list_consents(actor_scope(socket)),
         consent when is_map(consent) <- find_consent(consents, purpose_code),
         attributes = consent_attributes(consent, state),
         {:ok, _command} <-
           attributes |> Privacy.change_consent() |> Ecto.Changeset.apply_action(:update),
         {:ok, updated} <- Privacy.put_consent(actor_scope(socket), purpose_code, attributes) do
      {:noreply,
       socket
       |> stream_insert(:consents, updated)
       |> put_flash(:info, gettext("Your consent choice was saved."))}
    else
      :error ->
        expired_session(socket)

      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("This consent choice is no longer available."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("The consent choice was invalid."))}

      {:error, :profile_required} ->
        profile_required(socket)

      {:error, :consent_unavailable} ->
        {:noreply,
         put_flash(socket, :error, gettext("This consent choice is no longer available."))}

      {:error, reason} ->
        Logger.error("could not update member consent", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, gettext("Your consent could not be updated."))}
    end
  end

  def handle_event("put_consent", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The consent choice was invalid."))}
  end

  def handle_event("validate_request", %{"privacy_request" => params}, socket)
      when is_map(params) do
    changeset =
      socket
      |> request_attributes(params)
      |> Privacy.change_request_submission()

    {:noreply,
     assign(
       socket,
       :request_form,
       to_form(%{changeset | action: :validate}, as: :privacy_request)
     )}
  end

  def handle_event("validate_request", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The data request form was invalid."))}
  end

  def handle_event("submit_request", %{"privacy_request" => params}, socket)
      when is_map(params) do
    attributes = request_attributes(socket, params)

    with {:ok, socket} <- refresh_session(socket),
         {:ok, _submission} <-
           attributes
           |> Privacy.change_request_submission()
           |> Ecto.Changeset.apply_action(:insert),
         {:ok, %{request: request}} <-
           Privacy.submit_request(actor_scope(socket), attributes) do
      {:noreply,
       socket
       |> rotate_request_form()
       |> stream_insert(:requests, request, at: 0)
       |> put_flash(:info, gettext("Your data request was sent."))}
    else
      :error ->
        expired_session(socket)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :request_form, to_form(changeset, as: :privacy_request))}

      {:error, :profile_required} ->
        profile_required(socket)

      {:error, :idempotency_conflict} ->
        {:noreply,
         put_flash(socket, :error, gettext("This data request conflicts with a previous one."))}

      {:error, reason} ->
        Logger.error("could not submit member privacy request", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, gettext("Your data request could not be sent."))}
    end
  end

  def handle_event("submit_request", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The data request form was invalid."))}
  end

  defp load_privacy(socket) do
    scope = actor_scope(socket)

    with {:ok, consents} <- Privacy.list_consents(scope),
         {:ok, requests} <- Privacy.list_requests(scope) do
      socket
      |> assign_request_form(%{})
      |> stream(:consents, consents, reset: true)
      |> stream(:requests, requests, reset: true)
    else
      {:error, :profile_required} ->
        profile_required_redirect(socket)

      {:error, reason} ->
        Logger.error("could not load member privacy", reason: inspect(reason))

        socket
        |> put_flash(:error, gettext("Your privacy settings are temporarily unavailable."))
        |> redirect(to: ~p"/app")
    end
  end

  defp assign_request_form(socket, attributes) do
    client_request_id =
      Map.get_lazy(socket.assigns, :request_client_id, fn ->
        Ecto.UUID.generate(version: 7, precision: :monotonic)
      end)

    attributes =
      attributes
      |> Map.put("client_request_id", client_request_id)
      |> Map.put_new("request_type", "access")

    socket
    |> assign(:request_client_id, client_request_id)
    |> assign(
      :request_form,
      attributes |> Privacy.change_request_submission() |> to_form(as: :privacy_request)
    )
  end

  defp rotate_request_form(socket) do
    socket
    |> assign(
      :request_client_id,
      Ecto.UUID.generate(version: 7, precision: :monotonic)
    )
    |> assign_request_form(%{})
  end

  defp request_attributes(socket, params) do
    params
    |> Map.take(["request_type"])
    |> Map.put("client_request_id", socket.assigns.request_client_id)
  end

  defp refresh_session(socket) do
    case Accounts.refresh_scope(socket.assigns.current_account_scope) do
      {:ok, account_scope} -> {:ok, assign(socket, :current_account_scope, account_scope)}
      :error -> :error
    end
  end

  defp find_consent(consents, purpose_code) do
    Enum.find(consents, &(&1.processing_purpose.code == purpose_code))
  end

  defp consent_attributes(consent, state) do
    %{
      "state" => state,
      "legal_document_version_id" => consent.processing_purpose.current_legal_document_version_id
    }
  end

  defp profile_required(socket) do
    {:noreply, profile_required_redirect(socket)}
  end

  defp profile_required_redirect(socket) do
    socket
    |> put_flash(:error, gettext("Complete your profile before managing privacy."))
    |> redirect(to: ~p"/app/profile")
  end

  defp expired_session(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Your session has expired. Sign in again."))
     |> redirect(to: ~p"/app/login")}
  end

  defp actor_scope(socket) do
    account_scope = socket.assigns.current_account_scope
    ActorScope.new!(account_scope.user.id, account_scope.request_id)
  end

  defp consent_state_label("granted"), do: gettext("Granted")
  defp consent_state_label("withdrawn"), do: gettext("Withdrawn")
  defp consent_state_label("not_set"), do: gettext("Not decided")
  defp consent_state_label(state), do: state

  defp request_type_label("access"), do: gettext("Access my data")
  defp request_type_label("confirmation"), do: gettext("Confirm data processing")
  defp request_type_label("correction"), do: gettext("Correct my data")
  defp request_type_label("portability"), do: gettext("Export my data")
  defp request_type_label("deletion"), do: gettext("Delete my data")
  defp request_type_label("anonymization"), do: gettext("Anonymize my data")
  defp request_type_label("consent_withdrawal"), do: gettext("Withdraw consent")
  defp request_type_label("information"), do: gettext("Request information")
  defp request_type_label(type), do: type

  defp request_status_label("received"), do: gettext("Received")
  defp request_status_label("identity_verification"), do: gettext("Identity verification")
  defp request_status_label("in_progress"), do: gettext("In progress")
  defp request_status_label("completed"), do: gettext("Completed")
  defp request_status_label("partially_completed"), do: gettext("Partially completed")
  defp request_status_label("rejected"), do: gettext("Rejected")
  defp request_status_label("cancelled"), do: gettext("Cancelled")
  defp request_status_label(status), do: status

  defp timestamp(nil, _locale), do: gettext("Not available")
  defp timestamp(value, "pt_BR"), do: Calendar.strftime(value, "%d/%m/%Y · %H:%M")
  defp timestamp(value, _locale), do: Calendar.strftime(value, "%Y-%m-%d · %H:%M")
end
