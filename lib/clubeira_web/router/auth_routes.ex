defmodule ClubeiraWeb.Router.AuthRoutes do
  @moduledoc false

  defmacro auth_routes do
    quote do
      scope "/api/v1", ClubeiraWeb.Auth do
        pipe_through [:api, :login_api]

        post "/auth/sessions", SessionController, :create, as: :auth_session
      end

      scope "/api/v1", ClubeiraWeb.Auth do
        pipe_through [:api, :registration_api]

        post "/auth/registrations", RegistrationController, :create
      end

      scope "/api/v1", ClubeiraWeb.Auth do
        pipe_through [:api, :password_reset_request_api]

        post "/auth/password-reset-requests", PasswordResetRequestController, :create
      end

      scope "/api/v1", ClubeiraWeb.Auth do
        pipe_through [:api, :password_reset_api]

        post "/auth/password-resets", PasswordResetController, :create
      end

      scope "/api/v1", ClubeiraWeb.Auth do
        pipe_through [:api, :email_verification_api]

        post "/auth/email-verifications", EmailVerificationController, :create
      end

      scope "/api/v1", ClubeiraWeb.Auth do
        pipe_through [:api, :authenticated_api, :email_verification_request_api]

        post "/auth/email-verification-requests", EmailVerificationRequestController, :create
      end

      scope "/api/v1", ClubeiraWeb.Auth do
        pipe_through [:api, :authenticated_api]

        delete "/auth/session", SessionController, :delete, as: :auth_session
      end
    end
  end
end
