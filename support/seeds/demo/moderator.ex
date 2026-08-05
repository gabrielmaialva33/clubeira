defmodule Clubeira.Seeds.Demo.Moderator do
  @moduledoc false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Factory
  alias Clubeira.Repo
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Demo.Ids
  alias Clubeira.Seeds.Writer

  @default_email "moderador.demo@clubeira.local"
  @default_password "clubeira-moderador-local"
  @range_start ~U[2026-01-01 00:00:00Z]
  @user_fields ~w(email status disabled_at updated_at)a

  @spec run!() :: map()
  def run! do
    user = seed_user!()

    seed_membership!(user,
      polo_id: id(:polo_sobral),
      role_id: id(:review_moderator_role_sobral),
      membership_id: id(:moderator_membership_sobral)
    )

    seed_membership!(user,
      polo_id: id(:polo_londrina),
      role_id: id(:review_moderator_role_londrina),
      membership_id: id(:moderator_membership_londrina)
    )

    %{email: user.email, polos: 2}
  end

  defp seed_user! do
    email = System.get_env("CLUBEIRA_DEMO_MODERATOR_EMAIL", @default_email)

    user =
      Writer.upsert!(
        :user,
        %{id: id(:moderator_user), email: email, status: "active"},
        @user_fields
      )

    password = System.get_env("CLUBEIRA_DEMO_MODERATOR_PASSWORD", @default_password)

    unless current_password?(user, password) do
      case Accounts.set_password(user, password) do
        {:ok, _credential} ->
          :ok

        {:error, changeset} ->
          raise "invalid CLUBEIRA_DEMO_MODERATOR_PASSWORD: #{inspect(changeset.errors)}"
      end
    end

    user
  end

  defp seed_membership!(user, options) do
    polo_id = Keyword.fetch!(options, :polo_id)

    Seeds.with_polo!(polo_id, fn ->
      role =
        Writer.insert_once!(:polo_role, %{
          id: Keyword.fetch!(options, :role_id),
          polo_id: polo_id,
          key: "review_moderator",
          name: "Moderação de avaliações",
          status: "active"
        })

      membership =
        Writer.insert_once!(:polo_membership, %{
          id: Keyword.fetch!(options, :membership_id),
          polo_id: polo_id,
          user_id: user.id,
          valid_during: Factory.tstz_range(@range_start),
          status: "active"
        })

      Writer.insert_once!(:polo_membership_role, %{
        polo_id: polo_id,
        polo_membership_id: membership.id,
        polo_role_id: role.id,
        inserted_at: @range_start
      })
    end)
  end

  defp current_password?(user, password) do
    case Repo.get(PasswordCredential, user.id) do
      %PasswordCredential{password_hash: password_hash} ->
        Argon2.verify_pass(password, password_hash)

      nil ->
        false
    end
  end

  defp id(name), do: Ids.fetch!(name)
end
