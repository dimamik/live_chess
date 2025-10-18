defmodule LiveChessWeb.Router do
  use LiveChessWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LiveChessWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # plug :put_csp_headers
  end

  # defp put_csp_headers(conn, _opts) do
  #   # Content Security Policy for enhanced security
  #   # - default-src 'self': Only allow resources from same origin
  #   # - script-src adds 'unsafe-inline' for LiveView and 'unsafe-eval' for Stockfish WASM
  #   # - style-src adds 'unsafe-inline' for inline styles
  #   # - img-src adds data: for inline SVG pieces
  #   # - connect-src adds wss: for LiveView websocket connections
  #   csp_value =
  #     [
  #       "default-src 'self'",
  #       "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
  #       "style-src 'self' 'unsafe-inline'",
  #       "img-src 'self' data:",
  #       "connect-src 'self' ws: wss:",
  #       "font-src 'self' data:"
  #     ]
  #     |> Enum.join("; ")

  #   Plug.Conn.put_resp_header(conn, "content-security-policy", csp_value)
  # end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", LiveChessWeb do
    pipe_through :browser

    live_session :default, on_mount: LiveChessWeb.PlayerLiveAuth do
      live "/", LobbyLive, :index
      live "/game/:room_id", GameLive, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", LiveChessWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:live_chess, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LiveChessWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
