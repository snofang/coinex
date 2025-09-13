defmodule CoinexWeb.Router do
  use CoinexWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CoinexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CoinexWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/trading", TradingLive, :index
  end

  # CoinEx Futures API endpoints
  scope "/perpetual/v1", CoinexWeb do
    pipe_through :api

    # Market data endpoints
    get "/market/ticker", FuturesController, :ticker
    get "/market/list", FuturesController, :market_list

    # Order management endpoints
    post "/order/put_limit", FuturesController, :put_limit_order
    post "/order/put_market", FuturesController, :put_market_order
    post "/order/cancel", FuturesController, :cancel_order
    get "/order/pending", FuturesController, :pending_orders

    # Position endpoints
    get "/position/pending", FuturesController, :pending_positions

    # Asset endpoints
    get "/asset/query", FuturesController, :query_asset
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:coinex, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CoinexWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
