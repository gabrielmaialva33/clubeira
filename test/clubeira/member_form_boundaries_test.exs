defmodule Clubeira.MemberFormBoundariesTest do
  use ExUnit.Case, async: true

  alias Clubeira.Accounts
  alias Clubeira.Accounts.EmailVerificationSubmission
  alias Clubeira.Accounts.PasswordResetCompletion
  alias Clubeira.Accounts.PasswordResetRequest
  alias Clubeira.Accounts.Registration
  alias Clubeira.Billing
  alias Clubeira.Billing.BillingAgreementStartRequest
  alias Clubeira.Billing.CheckoutRequest
  alias Clubeira.Billing.PaymentStartRequest
  alias Clubeira.People
  alias Clubeira.People.SelfProfileRequest
  alias Clubeira.Privacy
  alias Clubeira.Privacy.ConsentCommand
  alias Clubeira.Privacy.RequestSubmission
  alias Clubeira.Reviews
  alias Clubeira.Reviews.PartnerResponseRequest
  alias Clubeira.Reviews.ReviewReportRequest
  alias Clubeira.Reviews.Submission

  test "member contexts expose forms from the command changesets" do
    profile = People.change_self_profile(%{"display_name" => "  Gabriel Maia  "})
    assert %SelfProfileRequest{} = profile.data
    assert Ecto.Changeset.get_field(profile, :display_name) == "Gabriel Maia"

    consent =
      Privacy.change_consent(%{
        "state" => "granted",
        "legal_document_version_id" => Ecto.UUID.generate()
      })

    assert %ConsentCommand{} = consent.data
    assert Ecto.Changeset.get_field(consent, :state) == "granted"

    request =
      Privacy.change_request_submission(%{
        "client_request_id" => Ecto.UUID.generate(),
        "request_type" => "access"
      })

    assert %RequestSubmission{} = request.data
    assert Ecto.Changeset.get_field(request, :request_type) == "access"
  end

  test "account contexts expose registration and recovery forms" do
    registration =
      Accounts.change_registration(%{
        "email" => "  MEMBRO@Example.Test ",
        "password" => "uma-senha-forte-de-teste",
        "legal_document_version_ids" => [Ecto.UUID.generate()]
      })

    assert %Registration{} = registration.data
    assert Ecto.Changeset.get_field(registration, :email) == "membro@example.test"

    request = Accounts.change_password_reset_request(%{"email" => " membro@example.test "})
    assert %PasswordResetRequest{} = request.data
    assert Ecto.Changeset.get_field(request, :email) == "membro@example.test"

    reset =
      Accounts.change_password_reset(%{
        "token" => String.duplicate("a", 43),
        "password" => "uma-nova-senha-forte"
      })

    assert %PasswordResetCompletion{} = reset.data

    verification =
      Accounts.change_email_verification(%{"token" => String.duplicate("b", 43)})

    assert %EmailVerificationSubmission{} = verification.data
  end

  test "checkout contexts expose provider-neutral command forms" do
    order_id = Ecto.UUID.generate()

    checkout =
      Billing.change_checkout_request(%{
        "product_offering_version_id" => Ecto.UUID.generate(),
        "offering_price_id" => Ecto.UUID.generate(),
        "idempotency_key" => "checkout-form-123"
      })

    assert %CheckoutRequest{} = checkout.data
    assert Ecto.Changeset.get_field(checkout, :quantity) == 1

    payment =
      Billing.change_payment_start_request(%{
        "order_id" => order_id,
        "payment_method" => "pix",
        "idempotency_key" => "payment-form-123"
      })

    assert %PaymentStartRequest{} = payment.data
    assert Ecto.Changeset.get_field(payment, :order_id) == order_id

    agreement =
      Billing.change_billing_agreement_start_request(%{
        "order_id" => order_id,
        "idempotency_key" => "agreement-form-123"
      })

    assert %BillingAgreementStartRequest{} = agreement.data
    assert Ecto.Changeset.get_field(agreement, :order_id) == order_id
  end

  test "review contexts expose member and partner command forms" do
    submission =
      Reviews.change_verified_submission(%{
        "place_id" => Ecto.UUID.generate(),
        "source_redemption_id" => Ecto.UUID.generate(),
        "rating" => 5,
        "body" => "  Atendimento excelente.  ",
        "idempotency_key" => "review-form-123"
      })

    assert %Submission{} = submission.data
    assert Ecto.Changeset.get_field(submission, :body) == "Atendimento excelente."

    report =
      Reviews.change_review_report_request(%{
        "place_id" => Ecto.UUID.generate(),
        "review_id" => Ecto.UUID.generate(),
        "reason_code" => "spam",
        "idempotency_key" => "report-form-123"
      })

    assert %ReviewReportRequest{} = report.data
    assert Ecto.Changeset.get_field(report, :reason_code) == "spam"

    response =
      Reviews.change_partner_response_request(%{
        "body" => "  Obrigado pela visita.  ",
        "idempotency_key" => "response-form-123"
      })

    assert %PartnerResponseRequest{} = response.data
    assert Ecto.Changeset.get_field(response, :body) == "Obrigado pela visita."
  end

  test "all member form boundaries reject terms and structs without raising" do
    boundaries = [
      &People.change_self_profile/1,
      &Privacy.change_consent/1,
      &Privacy.change_request_submission/1,
      &Billing.change_checkout_request/1,
      &Billing.change_payment_start_request/1,
      &Billing.change_billing_agreement_start_request/1,
      &Reviews.change_verified_submission/1,
      &Reviews.change_review_report_request/1,
      &Reviews.change_partner_response_request/1,
      &Accounts.change_registration/1,
      &Accounts.change_password_reset_request/1,
      &Accounts.change_password_reset/1,
      &Accounts.change_email_verification/1
    ]

    for boundary <- boundaries, attributes <- [:invalid, %URI{}] do
      changeset = boundary.(attributes)

      refute changeset.valid?
      assert {:base, {"must be a map", []}} in changeset.errors
    end
  end

  test "account command constructors reject terms and structs as changesets" do
    constructors = [
      &PasswordResetRequest.new/1,
      &PasswordResetCompletion.new/1,
      &EmailVerificationSubmission.new/1
    ]

    for constructor <- constructors, attributes <- [:invalid, %URI{}] do
      assert {:error, changeset} = constructor.(attributes)
      assert {:base, {"must be a map", []}} in changeset.errors
    end
  end

  test "review command constructors preserve normalization and reject unsafe terms" do
    place_id = Ecto.UUID.generate(version: 7)
    review_id = Ecto.UUID.generate(version: 7)

    assert {:ok, submission} =
             Submission.new(%{
               place_id: place_id,
               source_redemption_id: review_id,
               rating: 5,
               title: "   ",
               body: "  Excelente atendimento.  ",
               idempotency_key: "review-request-001"
             })

    assert submission.title == nil
    assert submission.body == "Excelente atendimento."

    assert {:error, report} =
             ReviewReportRequest.new(%{
               place_id: place_id,
               review_id: review_id,
               reason_code: " OTHER ",
               details: "   ",
               idempotency_key: "report-request-001"
             })

    assert {:details, {"is required for other", []}} in report.errors

    constructors = [
      {&Submission.new/1, %Submission{}},
      {&ReviewReportRequest.new/1, %ReviewReportRequest{}},
      {&PartnerResponseRequest.new/1, %PartnerResponseRequest{}}
    ]

    for {constructor, struct} <- constructors, attributes <- [:invalid, struct] do
      assert {:error, changeset} = constructor.(attributes)
      assert {:base, {"must be a map", []}} in changeset.errors
    end

    assert {:error, report} =
             ReviewReportRequest.new(%{
               place_id: place_id,
               review_id: review_id,
               reason_code: 1,
               details: 2,
               idempotency_key: "invalid key"
             })

    refute report.valid?
  end
end
