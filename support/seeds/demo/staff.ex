defmodule Clubeira.Seeds.Demo.Staff do
  @moduledoc false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Factory
  alias Clubeira.Repo
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Writer

  @range_start ~U[2026-01-01 00:00:00Z]
  @user_fields ~w(email status disabled_at updated_at)a

  @spec seed!(keyword()) :: map()
  def seed!(options) do
    user = seed_user!(options)
    memberships = Keyword.fetch!(options, :memberships)

    Enum.each(memberships, &seed_membership!(user, &1, options))

    %{email: user.email, polos: length(memberships)}
  end

  defp seed_user!(options) do
    email = System.get_env(Keyword.fetch!(options, :email_env), Keyword.fetch!(options, :email))

    user =
      Writer.upsert!(
        :user,
        %{id: Keyword.fetch!(options, :user_id), email: email, status: "active"},
        @user_fields
      )

    password =
      System.get_env(
        Keyword.fetch!(options, :password_env),
        Keyword.fetch!(options, :password)
      )

    unless current_password?(user, password) do
      case Accounts.set_password(user, password) do
        {:ok, _credential} ->
          :ok

        {:error, changeset} ->
          raise "invalid #{Keyword.fetch!(options, :password_env)}: #{inspect(changeset.errors)}"
      end
    end

    user
  end

  defp seed_membership!(user, membership_options, staff_options) do
    polo_id = Keyword.fetch!(membership_options, :polo_id)

    Seeds.with_polo!(polo_id, fn ->
      role =
        Writer.insert_once!(:polo_role, %{
          id: Keyword.fetch!(membership_options, :role_id),
          polo_id: polo_id,
          key: Keyword.fetch!(staff_options, :role_key),
          name: Keyword.fetch!(staff_options, :role_name),
          status: "active"
        })

      membership =
        Writer.insert_once!(:polo_membership, %{
          id: Keyword.fetch!(membership_options, :membership_id),
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
end
