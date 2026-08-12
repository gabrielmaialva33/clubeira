defmodule ClubeiraWeb.Router.BackofficeRoutes do
  @moduledoc false

  defmacro backoffice_routes do
    quote do
      scope "/admin", ClubeiraWeb, as: :admin do
        pipe_through [:browser, :private_browser]

        get "/login", Auth.BrowserSessionController, :new
        delete "/logout", Auth.BrowserSessionController, :delete
      end

      scope "/admin", ClubeiraWeb, as: :admin do
        pipe_through [:browser, :private_browser, :login_api]

        post "/login", Auth.BrowserSessionController, :create
      end

      scope "/admin", ClubeiraWeb.Backoffice, as: :admin do
        pipe_through [:browser, :private_browser]

        live_session :backoffice,
          on_mount: [{ClubeiraWeb.BackofficeAuth, :ensure_authenticated}] do
          live "/", DashboardLive, :index
          live "/places", PlacesLive, :index
          live "/places/:polo_place_id", PlaceLive, :show
        end
      end

      scope "/api/v1/polos/:polo_slug/backoffice", ClubeiraWeb.Backoffice, as: :backoffice do
        pipe_through [:api, :authenticated_api]

        post "/partners", PartnerController, :create
        post "/places/:place_id/partner-accesses", PartnerAccessController, :create
        post "/partner-accesses/:access_id/revocations", PartnerAccessController, :revoke
        get "/places", PlaceController, :index
        post "/places/:place_id/lifecycle-actions", PlaceLifecycleController, :create
        put "/places/:place_id/profile", PlaceProfileController, :update
        post "/places/:place_id/benefit-offers", BenefitOfferController, :create
        get "/benefit-offers", BenefitOfferController, :index
        get "/product-offerings", ProductOfferingController, :index
        post "/product-offerings", ProductOfferingController, :create

        post "/product-offerings/:product_offering_id/lifecycle-actions",
             ProductOfferingLifecycleController,
             :create

        get "/partner-agreements", PartnerAgreementController, :index
        post "/partner-agreements", PartnerAgreementController, :create
        get "/partner-agreements/:agreement_id", PartnerAgreementController, :show
        get "/payments", PaymentController, :index
        get "/subscriptions", SubscriptionController, :index
        get "/outbox-messages", OperationsController, :outbox_messages
        post "/outbox-messages/:message_id/retries", OperationsController, :retry_outbox_message
        get "/audit-events", OperationsController, :audit_events

        post "/subscriptions/:contract_id/lifecycle-actions",
             SubscriptionLifecycleController,
             :create

        post "/payments/:payment_id/refunds", PaymentRefundController, :create
        get "/validation-points", ValidationPointController, :index
        post "/places/:place_id/validation-points", ValidationPointController, :create

        post "/validation-points/:validation_point_id/lifecycle-actions",
             ValidationPointLifecycleController,
             :create

        post "/validation-credentials/:credential_id/rotations",
             ValidationCredentialRotationController,
             :create

        post "/validation-credentials/:credential_id/revocations",
             ValidationCredentialRevocationController,
             :create

        get "/reviews", ReviewController, :index
        get "/review-reports", ReviewReportController, :index

        post "/review-reports/:review_report_id/moderation-actions",
             ReviewReportController,
             :create_action

        post "/reviews/:review_id/moderation-actions", ReviewController, :create_action
      end
    end
  end
end
