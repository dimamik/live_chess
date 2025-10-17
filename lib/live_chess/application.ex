defmodule LiveChess.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    restorer_child =
      if Application.get_env(:live_chess, :enable_game_restorer, true) do
        [LiveChess.GameRestorer]
      else
        []
      end

    children =
      [
        LiveChessWeb.Telemetry,
        LiveChess.Repo,
        {DNSCluster, query: Application.get_env(:live_chess, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: LiveChess.PubSub},
        {Registry, keys: :unique, name: LiveChess.GameRegistry},
        LiveChess.GameSupervisor,
        LiveChess.Engines.EvalCache
      ] ++
        restorer_child ++
        [
          # Start a worker by calling: LiveChess.Worker.start_link(arg)
          # {LiveChess.Worker, arg},
          # Start to serve requests, typically the last entry
          LiveChessWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LiveChess.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LiveChessWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
