defmodule Clubeira.Redemptions.ValidationPointLifecycleLock do
  @moduledoc false

  # Keep the original namespace stable so mixed deployments serialize together.
  @lock_prefix "validation-credential-lifecycle:"

  @spec acquire!(module(), Ecto.UUID.t()) :: :ok
  def acquire!(repo, validation_point_id) do
    lock_key = @lock_prefix <> validation_point_id
    repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key])
    :ok
  end
end
