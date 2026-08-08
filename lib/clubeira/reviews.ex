defmodule Clubeira.Reviews do
  @moduledoc """
  Authenticated member reviews for places visited through Clubeira.

  Verified submissions derive the author and polo from an authorized tenant
  scope, then prove the supplied redemption belongs to that actor and place.
  New reviews remain pending until a separate moderation boundary publishes
  or rejects them.
  """

  alias Clubeira.Reviews.ModerationAction
  alias Clubeira.Reviews.Review
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

  @spec list_for_moderation(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate list_for_moderation(scope, params), to: ReviewReader

  @spec list_public(Scope.t(), Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate list_public(scope, place_id, params), to: ReviewReader
end
