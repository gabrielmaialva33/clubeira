defmodule ClubeiraWeb.RedemptionConfirmationController do
  use ClubeiraWeb, :controller

  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Redemptions
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @conflict_errors ~w(
    entitlement_exhausted
    idempotency_conflict
    nonce_replayed
    request_in_progress
  )a

  def create(conn, %{"polo_slug" => polo_slug} = params) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with {:ok, validation_credential} <- validation_credential(conn),
         {:ok, idempotency_key} <- idempotency_key(conn),
         context <- RequestContext.new!(conn.assigns.request_id),
         {:ok, redemption} <-
           Redemptions.confirm_grant(
             polo_slug,
             %{
               grant: Map.get(params, "grant"),
               validation_credential: validation_credential,
               idempotency_key: idempotency_key
             },
             context
           ) do
      conn
      |> put_status(:created)
      |> render(:create, redemption: redemption)
    else
      {:error, reason}
      when reason in [:grant_invalid, :validation_credential_invalid, :credential_missing] ->
        unauthorized(conn)

      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, reason} when reason in @conflict_errors ->
        render_error(conn, :conflict)

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)

      {:error, _business_denial} ->
        render_error(conn, :unprocessable_entity)
    end
  end

  defp validation_credential(conn) do
    case get_req_header(conn, "authorization") do
      [authorization] when byte_size(authorization) <= 256 ->
        case String.split(String.trim(authorization), ~r/\s+/, parts: 2) do
          [scheme, credential] when credential != "" ->
            if String.downcase(scheme) == "validation",
              do: {:ok, credential},
              else: {:error, :credential_missing}

          _invalid ->
            {:error, :credential_missing}
        end

      _missing_or_ambiguous ->
        {:error, :credential_missing}
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] -> {:ok, key}
      _missing_or_ambiguous -> {:ok, nil}
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Validation realm="clubeira", error="invalid_credential")
    )
    |> render_error(:unauthorized)
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
