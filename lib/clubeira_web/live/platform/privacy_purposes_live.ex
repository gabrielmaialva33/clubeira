defmodule ClubeiraWeb.Platform.PrivacyPurposesLive do
  use ClubeiraWeb, :live_view

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Privacy
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.PlatformAuth
  alias ClubeiraWeb.PlatformComponents

  @default_legal_basis "consent"
  @purpose_fields ~w(code name legal_basis legal_document_version_id status)
  @put_fields ~w(name legal_basis legal_document_version_id status)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:purposes, dom_id: &"processing-purpose-#{&1.id}")
      |> assign(:page_title, gettext("Processing purposes"))
      |> assign(:editing_code, nil)

    case refresh_privacy_access(socket) do
      {:ok, socket, scope} -> load_workspace(socket, scope)
      {:error, reason} -> {:ok, redirect_access_error(socket, reason)}
    end
  end

  @impl true
  def handle_event("validate_purpose", %{"processing_purpose" => params}, socket)
      when is_map(params) and not is_struct(params) do
    params = bind_existing_code(socket, Map.take(params, @purpose_fields))
    legal_basis = Map.get(params, "legal_basis")

    if legal_basis == socket.assigns.selected_legal_basis do
      {:noreply, assign_validated_form(socket, params)}
    else
      with {:ok, socket, scope} <- refresh_privacy_access(socket),
           {:ok, legal_versions} <- list_legal_versions(scope, socket, legal_basis) do
        {:noreply,
         socket
         |> assign(:selected_legal_basis, legal_basis)
         |> assign(:legal_versions, legal_versions)
         |> assign_validated_form(params)}
      else
        {:error, reason} when reason in [:session_expired, :privacy_access_required] ->
          {:noreply, redirect_access_error(socket, reason)}

        {:error, :platform_privacy_officer_required} ->
          {:noreply, redirect_access_error(socket, :privacy_access_required)}

        {:error, :invalid_processing_purpose} ->
          {:noreply,
           socket
           |> assign(:selected_legal_basis, legal_basis)
           |> assign(:legal_versions, [])
           |> assign_validated_form(params)}

        {:error, reason} ->
          Logger.error("could not refresh legal evidence options", reason: inspect(reason))

          {:noreply,
           put_flash(socket, :error, gettext("Legal evidence options could not be refreshed."))}
      end
    end
  end

  def handle_event("validate_purpose", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The processing purpose form was invalid."))}
  end

  def handle_event("edit_purpose", %{"purpose-id" => purpose_id}, socket)
      when is_binary(purpose_id) do
    with {:ok, socket, scope} <- refresh_privacy_access(socket),
         {:ok, purposes} <- Privacy.list_processing_purposes(scope),
         purpose when not is_nil(purpose) <- Enum.find(purposes, &(&1.id == purpose_id)),
         {:ok, legal_versions} <- list_legal_versions(scope, socket, purpose.legal_basis) do
      {:noreply,
       socket
       |> assign(:editing_code, purpose.code)
       |> assign(:selected_legal_basis, purpose.legal_basis)
       |> assign(:legal_versions, legal_versions)
       |> assign(:purpose_form, purpose_form(purpose))
       |> stream(:purposes, purposes, reset: true)}
    else
      {:error, reason} when reason in [:session_expired, :privacy_access_required] ->
        {:noreply, redirect_access_error(socket, reason)}

      {:error, :platform_privacy_officer_required} ->
        {:noreply, redirect_access_error(socket, :privacy_access_required)}

      nil ->
        {:noreply, put_flash(socket, :error, gettext("The processing purpose was not found."))}

      {:error, reason} ->
        Logger.error("could not prepare a processing purpose for editing",
          purpose_id: purpose_id,
          reason: inspect(reason)
        )

        {:noreply,
         put_flash(socket, :error, gettext("The processing purpose could not be opened."))}
    end
  end

  def handle_event("edit_purpose", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The processing purpose was not found."))}
  end

  def handle_event("new_purpose", _params, socket) do
    with {:ok, socket, scope} <- refresh_privacy_access(socket),
         {:ok, legal_versions} <-
           list_legal_versions(scope, socket, @default_legal_basis) do
      {:noreply,
       socket
       |> assign(:editing_code, nil)
       |> assign(:selected_legal_basis, @default_legal_basis)
       |> assign(:legal_versions, legal_versions)
       |> assign(:purpose_form, new_purpose_form(legal_versions))}
    else
      {:error, reason} when reason in [:session_expired, :privacy_access_required] ->
        {:noreply, redirect_access_error(socket, reason)}

      {:error, :platform_privacy_officer_required} ->
        {:noreply, redirect_access_error(socket, :privacy_access_required)}

      {:error, reason} ->
        Logger.error("could not prepare a new processing purpose", reason: inspect(reason))

        {:noreply,
         put_flash(socket, :error, gettext("A new processing purpose could not be prepared."))}
    end
  end

  def handle_event("save_purpose", %{"processing_purpose" => params}, socket)
      when is_map(params) and not is_struct(params) do
    params = Map.take(params, @purpose_fields)
    code = socket.assigns.editing_code || Map.get(params, "code")

    case refresh_privacy_access(socket) do
      {:ok, socket, scope} ->
        put_purpose(socket, scope, code, Map.take(params, @put_fields), params)

      {:error, reason} ->
        {:noreply, redirect_access_error(socket, reason)}
    end
  end

  def handle_event("save_purpose", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The processing purpose form was invalid."))}
  end

  defp put_purpose(socket, scope, code, attributes, form_params) do
    case Privacy.put_processing_purpose(scope, code, attributes) do
      {:ok, _purpose} ->
        reload_after_save(socket, scope)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:purpose_form, to_form(changeset, as: :processing_purpose))
         |> put_flash(:error, gettext("Review the processing purpose before submitting."))}

      {:error, reason}
      when reason in [
             :invalid_processing_purpose,
             :consent_notice_unavailable,
             :legal_document_unavailable
           ] ->
        {:noreply,
         socket
         |> assign_validated_form(bind_existing_code(socket, form_params))
         |> put_flash(
           :error,
           gettext("The selected processing purpose or legal evidence is not available.")
         )}

      {:error, :platform_privacy_officer_required} ->
        {:noreply, redirect_access_error(socket, :privacy_access_required)}

      {:error, reason} ->
        Logger.error("could not save processing purpose",
          purpose_code: code,
          reason: inspect(reason)
        )

        {:noreply,
         put_flash(socket, :error, gettext("The processing purpose could not be saved."))}
    end
  end

  defp load_workspace(socket, scope) do
    with {:ok, purposes} <- Privacy.list_processing_purposes(scope),
         {:ok, legal_versions} <-
           list_legal_versions(scope, socket, @default_legal_basis) do
      {:ok,
       socket
       |> assign(:selected_legal_basis, @default_legal_basis)
       |> assign(:legal_versions, legal_versions)
       |> assign(:purpose_form, new_purpose_form(legal_versions))
       |> stream(:purposes, purposes, reset: true)}
    else
      {:error, :platform_privacy_officer_required} ->
        {:ok, redirect_access_error(socket, :privacy_access_required)}

      {:error, reason} ->
        Logger.error("could not load processing purpose workspace", reason: inspect(reason))

        {:ok,
         socket
         |> put_flash(:error, gettext("Processing purposes are temporarily unavailable."))
         |> redirect(to: ~p"/platform")}
    end
  end

  defp reload_after_save(socket, scope) do
    with {:ok, purposes} <- Privacy.list_processing_purposes(scope),
         {:ok, legal_versions} <-
           list_legal_versions(scope, socket, @default_legal_basis) do
      {:noreply,
       socket
       |> assign(:editing_code, nil)
       |> assign(:selected_legal_basis, @default_legal_basis)
       |> assign(:legal_versions, legal_versions)
       |> assign(:purpose_form, new_purpose_form(legal_versions))
       |> stream(:purposes, purposes, reset: true)
       |> put_flash(:info, gettext("The processing purpose was saved."))}
    else
      {:error, :platform_privacy_officer_required} ->
        {:noreply, redirect_access_error(socket, :privacy_access_required)}

      {:error, reason} ->
        Logger.error("could not reload processing purposes after saving", reason: inspect(reason))

        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("The purpose was saved, but the list could not be reloaded.")
         )
         |> redirect(to: ~p"/platform/privacy/purposes")}
    end
  end

  defp list_legal_versions(scope, socket, legal_basis) do
    Privacy.list_processing_purpose_legal_versions(scope, %{
      "locale" => legal_locale(socket.assigns.locale),
      "legal_basis" => legal_basis
    })
  end

  defp new_purpose_form(legal_versions) do
    %{
      "code" => "",
      "name" => "",
      "legal_basis" => @default_legal_basis,
      "legal_document_version_id" => first_legal_version_id(legal_versions),
      "status" => "active"
    }
    |> Privacy.change_processing_purpose()
    |> to_form(as: :processing_purpose)
  end

  defp purpose_form(purpose) do
    purpose
    |> Privacy.change_processing_purpose()
    |> to_form(as: :processing_purpose)
  end

  defp first_legal_version_id([version | _rest]), do: version.id
  defp first_legal_version_id([]), do: nil

  defp assign_validated_form(socket, params) do
    changeset = Privacy.change_processing_purpose(params)

    assign(
      socket,
      :purpose_form,
      to_form(%{changeset | action: :validate}, as: :processing_purpose)
    )
  end

  defp bind_existing_code(%{assigns: %{editing_code: code}}, params) when is_binary(code),
    do: Map.put(params, "code", code)

  defp bind_existing_code(_socket, params), do: params

  defp refresh_privacy_access(socket) do
    with {:ok, account_scope} <- Accounts.refresh_scope(socket.assigns.current_account_scope),
         {:ok, access} <- PlatformAuth.authorize(account_scope),
         true <- :manage_privacy in access.capabilities do
      scope = ActorScope.new!(account_scope.user.id, account_scope.request_id)

      {:ok,
       socket
       |> assign(:current_account_scope, account_scope)
       |> assign(:platform_access, access), scope}
    else
      :error -> {:error, :session_expired}
      _forbidden -> {:error, :privacy_access_required}
    end
  end

  defp redirect_access_error(socket, :session_expired) do
    socket
    |> put_flash(:error, gettext("Your session has expired. Sign in again to continue."))
    |> redirect(to: ~p"/platform/login")
  end

  defp redirect_access_error(socket, :privacy_access_required) do
    socket
    |> put_flash(:error, gettext("You do not have access to privacy operations."))
    |> redirect(to: ~p"/platform")
  end

  defp legal_locale(locale) when is_binary(locale), do: String.replace(locale, "_", "-")
  defp legal_locale(locale), do: locale

  defp legal_version_options(versions) do
    [
      {gettext("Select legal evidence when required"), ""}
      | Enum.map(versions, &{legal_version_label(&1), &1.id})
    ]
  end

  defp legal_version_label(version) do
    gettext("%{code} · %{kind} · %{audience} · %{locale} v%{version}",
      code: version.code,
      kind: humanized(version.document_kind),
      audience: humanized(version.audience),
      locale: version.locale,
      version: version.version
    )
  end

  defp legal_basis_options do
    [
      {gettext("Consent"), "consent"},
      {gettext("Contract"), "contract"},
      {gettext("Legal obligation"), "legal_obligation"},
      {gettext("Legitimate interest"), "legitimate_interest"},
      {gettext("Credit protection"), "credit_protection"},
      {gettext("Fraud prevention"), "fraud_prevention"}
    ]
  end

  defp status_options do
    [{gettext("Active"), "active"}, {gettext("Retired"), "retired"}]
  end

  defp humanized(value), do: value |> to_string() |> String.replace("_", " ")
end
