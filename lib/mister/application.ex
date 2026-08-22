defmodule Mister.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MisterWeb.Telemetry,
      Mister.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:mister, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:mister, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Mister.PubSub},
      Mister.Auth,
      {Oban, Application.fetch_env!(:mister, Oban)},
      # Start to serve requests, typically the last entry
      MisterWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mister.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MisterWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, migrations are run when NOT using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
