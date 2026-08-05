defmodule Clubeira.Reviews do
  @moduledoc """
  Authenticated member reviews for places visited through Clubeira.

  Verified submissions derive the author and polo from an authorized tenant
  scope, then prove the supplied redemption belongs to that actor and place.
  New reviews remain pending until a separate moderation boundary publishes
  or rejects them.
  """

  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewRevision
  alias Clubeira.Reviews.VerifiedReviewSubmitter
  alias Clubeira.Tenancy.Scope

  @type submission :: %{review: Review.t(), revision: ReviewRevision.t()}

  @spec submit_verified(Scope.t(), map()) ::
          {:ok, submission()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate submit_verified(scope, attributes), to: VerifiedReviewSubmitter, as: :submit
end
