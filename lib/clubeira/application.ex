defmodule Clubeira.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ClubeiraWeb.Telemetry,
        Clubeira.Repo,
        {Clubeira.Security.LoginRateLimiter, clean_period: :timer.minutes(1)},
        {Clubeira.Security.PasswordGate,
         Application.fetch_env!(:clubeira, Clubeira.Security.PasswordGate)}
      ] ++
        session_janitor_children() ++
        [
          {DNSCluster, query: Application.get_env(:clubeira, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Clubeira.PubSub},
          ClubeiraWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Clubeira.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ClubeiraWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp session_janitor_children do
    options = Application.fetch_env!(:clubeira, Clubeira.Accounts.SessionJanitor)

    if Keyword.get(options, :enabled, false) do
      [{Clubeira.Accounts.SessionJanitor, Keyword.delete(options, :enabled)}]
    else
      []
    end
  end
end
