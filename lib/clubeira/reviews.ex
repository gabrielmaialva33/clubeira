defmodule Clubeira.Reviews do
  @moduledoc """
  Authenticated member reviews for places visited through Clubeira.

  Verified submissions derive the author and polo from an authorized tenant
  scope, then prove the supplied redemption belongs to that actor and place.
  New reviews remain pending until a separate moderation boundary publishes
  or rejects them.
  """

  alias Clubeira.Reviews.ModerationAction
  alias Clubeira.Reviews.PartnerResponseWriter
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewMediaRegistrar
  alias Clubeira.Reviews.ReviewModerator
  alias Clubeira.Reviews.ReviewReader
  alias Clubeira.Reviews.ReviewReporter
  alias Clubeira.Reviews.ReviewReportReader
  alias Clubeira.Reviews.ReviewReportResolver
  alias Clubeira.Reviews.ReviewRevision
  alias Clubeira.Reviews.VerifiedReviewSubmitter
  alias Clubeira.Tenancy.Scope

  @type submission :: %{review: Review.t(), revision: ReviewRevision.t()}
  @type moderation :: %{review: Review.t(), action: ModerationAction.t()}

  @spec submit_verified(Scope.t(), map()) ::
          {:ok, submission()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate submit_verified(scope, attributes), to: VerifiedReviewSubmitter, as: :submit

  @spec moderate(Scope.t(), map()) ::
          {:ok, moderation()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate moderate(scope, attributes), to: ReviewModerator

  @spec report(Scope.t(), map()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate report(scope, attributes), to: ReviewReporter

  @spec list_reports(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate list_reports(scope, params), to: ReviewReportReader, as: :list

  @spec resolve_report(Scope.t(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate resolve_report(scope, attributes), to: ReviewReportResolver, as: :resolve

  @doc """
  Publishes the assigned operating organization's append-only response to a review.
  """
  @spec put_partner_response(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, term()}
  defdelegate put_partner_response(scope, review_id, attributes),
    to: PartnerResponseWriter,
    as: :put

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
end
