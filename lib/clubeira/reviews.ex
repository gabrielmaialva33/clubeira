defmodule Clubeira.Reviews do
  @moduledoc """
  Authenticated member reviews for places visited through Clubeira.

  Verified submissions derive the author and polo from an authorized tenant
  scope, then prove the supplied redemption belongs to that actor and place.
  New reviews remain pending until a separate moderation boundary publishes
  or rejects them.
  """

  alias Clubeira.Reviews.ModerationAction
  alias Clubeira.Reviews.ModerationRequest
  alias Clubeira.Reviews.PartnerResponseRequest
  alias Clubeira.Reviews.PartnerResponseWriter
  alias Clubeira.Reviews.PartnerReviewReader
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewMediaRegistrar
  alias Clubeira.Reviews.ReviewModerator
  alias Clubeira.Reviews.ReviewReader
  alias Clubeira.Reviews.ReviewReporter
  alias Clubeira.Reviews.ReviewReportReader
  alias Clubeira.Reviews.ReviewReportRequest
  alias Clubeira.Reviews.ReviewReportResolutionRequest
  alias Clubeira.Reviews.ReviewReportResolver
  alias Clubeira.Reviews.ReviewRevision
  alias Clubeira.Reviews.Submission
  alias Clubeira.Reviews.VerifiedReviewSubmitter
  alias Clubeira.Tenancy.Scope

  @type submission :: %{review: Review.t(), revision: ReviewRevision.t()}
  @type moderation :: %{review: Review.t(), action: ModerationAction.t()}

  @spec submit_verified(Scope.t(), map()) ::
          {:ok, submission()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate submit_verified(scope, attributes), to: VerifiedReviewSubmitter, as: :submit

  @doc false
  @spec change_verified_submission(term()) :: Ecto.Changeset.t()
  def change_verified_submission(attributes \\ %{}) do
    Submission.change(attributes)
  end

  @spec moderate(Scope.t(), map()) ::
          {:ok, moderation()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate moderate(scope, attributes), to: ReviewModerator

  @doc false
  @spec change_moderation_request(term()) :: Ecto.Changeset.t()
  def change_moderation_request(attributes \\ %{}) do
    ModerationRequest.change(attributes)
  end

  @spec report(Scope.t(), map()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate report(scope, attributes), to: ReviewReporter

  @doc false
  @spec change_review_report_request(term()) :: Ecto.Changeset.t()
  def change_review_report_request(attributes \\ %{}) do
    ReviewReportRequest.change(attributes)
  end

  @spec list_reports(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate list_reports(scope, params), to: ReviewReportReader, as: :list

  @spec resolve_report(Scope.t(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate resolve_report(scope, attributes), to: ReviewReportResolver, as: :resolve

  @doc false
  @spec change_review_report_resolution_request(term()) :: Ecto.Changeset.t()
  def change_review_report_resolution_request(attributes \\ %{}) do
    ReviewReportResolutionRequest.change(attributes)
  end

  @doc """
  Publishes the assigned operating organization's append-only response to a review.
  """
  @spec put_partner_response(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, term()}
  defdelegate put_partner_response(scope, review_id, attributes),
    to: PartnerResponseWriter,
    as: :put

  @doc false
  @spec change_partner_response_request(term()) :: Ecto.Changeset.t()
  def change_partner_response_request(attributes \\ %{}) do
    PartnerResponseRequest.change(attributes)
  end

  @doc """
  Lists published reviews for the authenticated partner's current place assignments.
  """
  @spec list_partner_reviews(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate list_partner_reviews(scope, params), to: PartnerReviewReader, as: :list

  @doc """
  Returns one published review inside the authenticated partner's current assignments.
  """
  @spec get_partner_review(Scope.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  defdelegate get_partner_review(scope, review_id), to: PartnerReviewReader, as: :get

  @doc """
  Registers trusted storage metadata for media owned by a pending review revision.
  """
  @spec register_media(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, term()}
  defdelegate register_media(scope, place_id, review_id, attributes),
    to: ReviewMediaRegistrar,
    as: :register

  @spec public_media_url(Scope.t(), Ecto.UUID.t()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate public_media_url(scope, media_id), to: ReviewMediaRegistrar, as: :public_url

  @spec list_for_moderation(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate list_for_moderation(scope, params), to: ReviewReader

  @spec list_public(Scope.t(), Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate list_public(scope, place_id, params), to: ReviewReader

  @spec get_public(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate get_public(scope, place_id, review_id), to: ReviewReader
end
