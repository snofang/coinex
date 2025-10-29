defmodule Coinex.PricePoller do
  @moduledoc """
  A GenServer that polls CoinEx API for market prices and publishes updates via PubSub.

  This module periodically fetches price data from the CoinEx futures API and broadcasts
  updates to subscribers via Phoenix.PubSub on the topic "price_updates:BTCUSDT".
  """

  use GenServer
  require Logger

  @market "BTCUSDT"
  # 1 minute
  @price_update_interval 60_000
  # 10 seconds on error
  @retry_interval 10_000

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Start price fetching immediately
    send(self(), :fetch_price)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:fetch_price, state) do
    case fetch_coinex_price() do
      {:ok, price} ->
        Logger.info("Fetched #{@market} price: #{price}")

        # Publish price update via PubSub
        Phoenix.PubSub.broadcast(
          Coinex.PubSub,
          "price_updates:#{@market}",
          {:price_update, @market, price}
        )

        # Schedule next price update
        Process.send_after(self(), :fetch_price, @price_update_interval)

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to fetch #{@market} price: #{inspect(reason)}")

        # Retry in 10 seconds
        Process.send_after(self(), :fetch_price, @retry_interval)

        {:noreply, state}
    end
  end

  ## Private Functions

  defp fetch_coinex_price do
    # Using CoinEx public API to get current BTCUSDT futures price
    url = "https://api.coinex.com/perpetual/v1/market/ticker?market=BTCUSDT"

    case Req.get(url) do
      {:ok, %{status: 200, body: %{"code" => 0, "data" => data}}} ->
        price = data["ticker"]["last"]
        {:ok, Decimal.new(price)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
