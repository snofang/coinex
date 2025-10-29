defmodule Coinex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CoinexWeb.Telemetry,
      Coinex.Repo,
      {DNSCluster, query: Application.get_env(:coinex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Coinex.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Coinex.Finch},
      # Start the Price Poller GenServer (must come before FuturesExchange)
      Coinex.PricePoller,
      # Start the Futures Exchange GenServer
      Coinex.FuturesExchange,
      # Start a worker by calling: Coinex.Worker.start_link(arg)
      # {Coinex.Worker, arg},
      # Start to serve requests, typically the last entry
      CoinexWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Coinex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CoinexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
