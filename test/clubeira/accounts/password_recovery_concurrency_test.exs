defmodule Clubeira.Accounts.PasswordRecoveryConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.EmailVerificationToken
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Accounts.PasswordResetToken
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Audit.SystemEvent
  alias Clubeira.Factory
  alias Clubeira.Repo

  @old_password "uma-senha-antiga-para-concorrencia"
  @first_password "primeira-senha-forte-concorrente"
  @second_password "segunda-senha-forte-concorrente"

  setup_all do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    database = "clubeira_password_recovery_concurrency_#{suffix}"

    with_admin_connection(fn admin ->
      Postgrex.query!(admin, ~s|CREATE DATABASE "#{database}" TEMPLATE template0|, [])
    end)

    on_exit(fn ->
      with_admin_connection(fn admin ->
        Postgrex.query!(admin, ~s|DROP DATABASE "#{database}" WITH (FORCE)|, [])
      end)
    end)

    repo =
      Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.put(:name, nil)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 6)
      |> then(&start_supervised!({Repo, &1}))

    Ecto.Migrator.run(
      Repo,
      Ecto.Migrator.migrations_path(Repo),
      :up,
      all: true,
      dynamic_repo: repo,
      log: false
    )

    {:ok, repo: repo}
  end

  setup %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    :ok
  end

  test "only one concurrent consumer can rotate the password", %{repo: repo} do
    user = Factory.insert(:user, email: "concurrent-reset@example.test")
    assert {:ok, _credential} = Accounts.set_password(user, @old_password)
    assert {:ok, old_session} = Accounts.login(user.email, @old_password)

    decoded_token = :crypto.strong_rand_bytes(32)
    token = Base.url_encode64(decoded_token, padding: false)
    now = DateTime.utc_now(:microsecond)

    assert {:ok, reset} =
             user
             |> PasswordResetToken.changeset(
               :crypto.hash(:sha256, decoded_token),
               DateTime.add(now, 1_800),
               now
             )
             |> Repo.insert()

    operations = [
      {@first_password,
       fn -> Accounts.reset_password(token, @first_password, RequestContext.new!()) end},
      {@second_password,
       fn -> Accounts.reset_password(token, @second_password, RequestContext.new!()) end}
    ]

    results = run_concurrently(repo, Enum.map(operations, &elem(&1, 1)))

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_password_reset})) == 1

    winning_password =
      operations
      |> Enum.zip(results)
      |> Enum.find_value(fn {{password, _operation}, result} ->
        if result == :ok, do: password
      end)

    losing_password =
      if winning_password == @first_password, do: @second_password, else: @first_password

    credential = Repo.get!(PasswordCredential, user.id)
    assert Argon2.verify_pass(winning_password, credential.password_hash)
    refute Argon2.verify_pass(losing_password, credential.password_hash)
    assert :error = Accounts.fetch_scope_by_api_token(old_session.token)
    assert %DateTime{} = Repo.get!(PasswordResetToken, reset.id).consumed_at

    assert Repo.aggregate(
             from(event in SystemEvent,
               where:
                 event.action == "authentication.password_reset.completed" and
                   event.resource_id == ^user.id
             ),
             :count
           ) == 1
  end

  test "concurrent email verification is idempotent and emits one audit event", %{repo: repo} do
    user = Factory.insert(:user, email: "concurrent-verification@example.test")
    decoded_token = :crypto.strong_rand_bytes(32)
    token = Base.url_encode64(decoded_token, padding: false)
    now = DateTime.utc_now(:microsecond)

    assert {:ok, verification} =
             user
             |> EmailVerificationToken.changeset(
               :crypto.hash(:sha256, decoded_token),
               DateTime.add(now, 86_400),
               now
             )
             |> Repo.insert()

    results =
      run_concurrently(repo, [
        fn -> Accounts.verify_email(token, RequestContext.new!()) end,
        fn -> Accounts.verify_email(token, RequestContext.new!()) end
      ])

    assert results == [:ok, :ok]
    assert %DateTime{} = Repo.get!(Clubeira.Accounts.User, user.id).email_verified_at
    assert %DateTime{} = Repo.get!(EmailVerificationToken, verification.id).consumed_at

    assert Repo.aggregate(
             from(event in SystemEvent,
               where: event.action == "account.email_verified" and event.resource_id == ^user.id
             ),
             :count
           ) == 1
  end

  defp run_concurrently(repo, operations) do
    caller = self()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(caller, {:ready, self()})

          receive do
            :run -> operation.()
          end
        end)
      end)

    ready_processes =
      Enum.map(tasks, fn _task ->
        receive do
          {:ready, process} -> process
        after
          5_000 -> flunk("concurrent password reset worker did not become ready")
        end
      end)

    Enum.each(ready_processes, &send(&1, :run))
    Task.await_many(tasks, 15_000)
  end

  defp connection_options(database) do
    Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :ssl, :socket_options])
    |> Keyword.put(:database, database)
  end

  defp with_admin_connection(operation) do
    {:ok, admin} = Postgrex.start_link(connection_options("postgres"))

    try do
      operation.(admin)
    after
      GenServer.stop(admin)
    end
  end
end
