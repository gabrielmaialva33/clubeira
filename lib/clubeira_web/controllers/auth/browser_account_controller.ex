defmodule ClubeiraWeb.Auth.BrowserAccountController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Legal

  @session_key "backoffice_session_token"
  @registration_documents_key "browser_registration_document_ids"
  @password_reset_token_key "browser_password_reset_token"
  @email_verification_token_key "browser_email_verification_token"

  def registration_new(conn, _params) do
    case registration_documents() do
      {:ok, documents} ->
        conn
        |> put_session(@registration_documents_key, Enum.map(documents, & &1.id))
        |> render_registration(documents, %{}, false, nil)

      {:error, _reason} ->
        registration_unavailable(conn)
    end
  end

  def registration_create(conn, raw_params) do
    params = registration_params(raw_params)

    with true <- Map.get(params, "accept_legal_documents") == "true",
         stored_ids when is_list(stored_ids) <- get_session(conn, @registration_documents_key),
         {:ok, documents} <- registration_documents(),
         current_ids = Enum.map(documents, & &1.id),
         true <- stored_ids == current_ids do
      register(conn, documents, params, current_ids)
    else
      _invalid_or_stale_acceptance ->
        case registration_documents() do
          {:ok, documents} ->
            conn
            |> put_session(@registration_documents_key, Enum.map(documents, & &1.id))
            |> render_registration(
              documents,
              params,
              false,
              gettext("Accept every current legal document to continue."),
              :unprocessable_entity
            )

          {:error, _reason} ->
            registration_unavailable(conn)
        end
    end
  end

  def password_reset_request_new(conn, _params) do
    render_password_reset_request(conn, Accounts.change_password_reset_request(), false)
  end

  def password_reset_request_create(conn, raw_params) do
    params = password_reset_request_params(raw_params)
    changeset = Accounts.change_password_reset_request(params)

    case Ecto.Changeset.apply_action(changeset, :request_password_reset) do
      {:ok, request} ->
        request_password_reset(request.email, conn)

      {:error, _changeset} ->
        :ok
    end

    render_password_reset_request(
      conn,
      Accounts.change_password_reset_request(),
      true,
      :accepted
    )
  end

  def password_reset_new(conn, %{"token" => token}) do
    conn =
      if valid_credential_field?(Accounts.change_password_reset(%{"token" => token}), :token) do
        put_session(conn, @password_reset_token_key, token)
      else
        delete_session(conn, @password_reset_token_key)
      end

    redirect(conn, to: ~p"/redefinir-senha")
  end

  def password_reset_new(conn, _params) do
    case get_session(conn, @password_reset_token_key) do
      token when is_binary(token) ->
        render_password_reset(conn, Accounts.change_password_reset(), false, nil)

      _missing_token ->
        render_password_reset(
          conn,
          nil,
          false,
          gettext("This password reset link is invalid or expired."),
          :unprocessable_entity
        )
    end
  end

  def password_reset_create(conn, raw_params) do
    params = password_reset_params(raw_params)

    case get_session(conn, @password_reset_token_key) do
      token when is_binary(token) -> reset_password(conn, token, params)
      _missing_token -> password_reset_invalid(conn)
    end
  end

  def email_verification_new(conn, %{"token" => token}) do
    conn =
      if valid_credential_field?(Accounts.change_email_verification(%{"token" => token}), :token) do
        put_session(conn, @email_verification_token_key, token)
      else
        delete_session(conn, @email_verification_token_key)
      end

    redirect(conn, to: ~p"/verificar-email")
  end

  def email_verification_new(conn, _params) do
    case get_session(conn, @email_verification_token_key) do
      token when is_binary(token) ->
        render_email_verification(conn, Accounts.change_email_verification(), false, nil)

      _missing_token ->
        render_email_verification(
          conn,
          nil,
          false,
          gettext("This email verification link is invalid or expired."),
          :unprocessable_entity
        )
    end
  end

  def email_verification_create(conn, _params) do
    case get_session(conn, @email_verification_token_key) do
      token when is_binary(token) -> verify_email(conn, token)
      _missing_token -> email_verification_invalid(conn)
    end
  end

  defp register(conn, documents, params, legal_document_version_ids) do
    attributes = %{
      "email" => Map.get(params, "email"),
      "password" => Map.get(params, "password"),
      "legal_document_version_ids" => legal_document_version_ids
    }

    case Accounts.register(attributes, RequestContext.new!(conn.assigns.request_id)) do
      {:ok, session} ->
        conn
        |> configure_session(renew: true)
        |> put_session(@session_key, session.token)
        |> delete_session(@registration_documents_key)
        |> put_flash(:info, gettext("Your account was created."))
        |> redirect(to: ~p"/app")

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset = scrub_sensitive_changes(changeset, [:password])
        render_registration(conn, documents, changeset, true, nil, :unprocessable_entity)

      {:error, :legal_acceptance_invalid} ->
        render_legal_acceptance_error(conn, params)

      {:error, :legal_documents_unavailable} ->
        registration_unavailable(conn)

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "1")
        |> render_registration(
          documents,
          params,
          true,
          gettext("Too many attempts. Wait a moment and try again."),
          :too_many_requests
        )
    end
  end

  defp request_password_reset(email, conn) do
    case Accounts.request_password_reset(email, request_context(conn)) do
      :ok ->
        :ok

      {:error, _reason} ->
        Logger.warning(
          "browser password reset request failed request_id=#{conn.assigns.request_id}"
        )
    end
  end

  defp reset_password(conn, token, params) do
    attributes = %{"token" => token, "password" => Map.get(params, "password")}
    changeset = Accounts.change_password_reset(attributes)

    case Ecto.Changeset.apply_action(changeset, :reset_password) do
      {:ok, reset} -> complete_password_reset(conn, reset)
      {:error, invalid_changeset} -> password_reset_changeset_error(conn, invalid_changeset)
    end
  end

  defp complete_password_reset(conn, reset) do
    case Accounts.reset_password(reset.token, reset.password, request_context(conn)) do
      :ok ->
        conn
        |> delete_session(@password_reset_token_key)
        |> render_password_reset(nil, true, nil)

      {:error, %Ecto.Changeset{} = changeset} ->
        password_reset_changeset_error(conn, changeset)

      {:error, :invalid_password_reset} ->
        password_reset_invalid(conn)

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "1")
        |> render_password_reset(
          Accounts.change_password_reset(),
          false,
          gettext("Too many attempts. Wait a moment and try again."),
          :too_many_requests
        )
    end
  end

  defp password_reset_changeset_error(conn, changeset) do
    conn
    |> render_password_reset(
      scrub_sensitive_changes(changeset, [:token, :password]),
      false,
      gettext("Check the new password and try again."),
      :unprocessable_entity
    )
  end

  defp password_reset_invalid(conn) do
    conn
    |> delete_session(@password_reset_token_key)
    |> render_password_reset(
      nil,
      false,
      gettext("This password reset link is invalid or expired."),
      :unprocessable_entity
    )
  end

  defp verify_email(conn, token) do
    changeset = Accounts.change_email_verification(%{"token" => token})

    with {:ok, verification} <- Ecto.Changeset.apply_action(changeset, :verify_email),
         :ok <- Accounts.verify_email(verification.token, request_context(conn)) do
      conn
      |> delete_session(@email_verification_token_key)
      |> render_email_verification(nil, true, nil)
    else
      {:error, _reason} -> email_verification_invalid(conn)
    end
  end

  defp email_verification_invalid(conn) do
    conn
    |> delete_session(@email_verification_token_key)
    |> render_email_verification(
      nil,
      false,
      gettext("This email verification link is invalid or expired."),
      :unprocessable_entity
    )
  end

  defp render_registration(conn, documents, form_source, accepted?, error, status \\ :ok) do
    form =
      case form_source do
        %Ecto.Changeset{} = changeset ->
          Phoenix.Component.to_form(changeset)

        attributes ->
          attributes
          |> registration_attributes()
          |> Accounts.change_registration()
          |> Phoenix.Component.to_form()
      end

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(status)
    |> render(:registration,
      page_title: gettext("Create your Clubeira account"),
      form: form,
      documents: documents,
      accepted?: accepted?,
      error: error
    )
  end

  defp render_password_reset_request(conn, changeset, sent?, status \\ :ok) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(status)
    |> render(:password_reset_request,
      page_title: gettext("Reset your password"),
      form: Phoenix.Component.to_form(changeset),
      sent?: sent?
    )
  end

  defp render_password_reset(conn, changeset, completed?, error, status \\ :ok) do
    form = if changeset, do: Phoenix.Component.to_form(changeset)

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(status)
    |> render(:password_reset,
      page_title: gettext("Choose a new password"),
      form: form,
      completed?: completed?,
      error: error
    )
  end

  defp render_email_verification(conn, changeset, completed?, error, status \\ :ok) do
    form = if changeset, do: Phoenix.Component.to_form(changeset)

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(status)
    |> render(:email_verification,
      page_title: gettext("Verify your email"),
      form: form,
      completed?: completed?,
      error: error
    )
  end

  defp registration_attributes(params) do
    Map.take(params, ["email"])
  end

  defp registration_params(%{"registration" => params} = raw_params) when is_map(params) do
    Map.merge(Map.take(raw_params, ["accept_legal_documents"]), params)
  end

  defp registration_params(params) when is_map(params), do: params
  defp registration_params(_params), do: %{}

  defp password_reset_request_params(%{"password_reset_request" => params})
       when is_map(params),
       do: params

  defp password_reset_request_params(params) when is_map(params), do: params
  defp password_reset_request_params(_params), do: %{}

  defp password_reset_params(%{"password_reset_completion" => params}) when is_map(params),
    do: params

  defp password_reset_params(params) when is_map(params), do: params
  defp password_reset_params(_params), do: %{}

  defp registration_documents do
    Legal.list_registration_documents(%{"locale" => "pt-BR"})
  end

  defp render_legal_acceptance_error(conn, params) do
    case registration_documents() do
      {:ok, documents} ->
        conn
        |> put_session(@registration_documents_key, Enum.map(documents, & &1.id))
        |> render_registration(
          documents,
          params,
          false,
          gettext("The legal documents changed. Review and accept them again."),
          :unprocessable_entity
        )

      {:error, _reason} ->
        registration_unavailable(conn)
    end
  end

  defp scrub_sensitive_changes(changeset, fields) do
    params = Map.drop(changeset.params || %{}, Enum.map(fields, &Atom.to_string/1))
    changes = Map.drop(changeset.changes, fields)

    %{changeset | params: params, changes: changes}
  end

  defp valid_credential_field?(changeset, field) do
    is_binary(Ecto.Changeset.get_field(changeset, field)) and
      not Keyword.has_key?(changeset.errors, field)
  end

  defp request_context(conn), do: RequestContext.new!(conn.assigns.request_id)

  defp registration_unavailable(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(:service_unavailable)
    |> render(:registration,
      page_title: gettext("Create your Clubeira account"),
      form: Phoenix.Component.to_form(Accounts.change_registration()),
      documents: [],
      accepted?: false,
      error: gettext("Registration is temporarily unavailable.")
    )
  end
end
