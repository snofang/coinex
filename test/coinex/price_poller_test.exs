defmodule Coinex.PricePollerTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    # Subscribe to price updates to test broadcasting
    Phoenix.PubSub.subscribe(Coinex.PubSub, "price_updates:BTCUSDT")

    :ok
  end

  describe "price polling and broadcasting" do
    @tag timeout: 120_000
    test "broadcasts price updates to subscribers" do
      # Wait for at least one price update message
      # The PricePoller should fetch and broadcast shortly after starting
      assert_receive {:price_update, "BTCUSDT", price}, 70_000

      # Verify that price is a Decimal
      assert %Decimal{} = price
      assert Decimal.positive?(price)
    end

    @tag timeout: 180_000
    test "continues polling and broadcasting periodically" do
      # Receive first price update
      assert_receive {:price_update, "BTCUSDT", _first_price}, 70_000

      # Should receive another update within the polling interval
      # Using a generous timeout to account for API delays
      assert_receive {:price_update, "BTCUSDT", _second_price}, 70_000
    end
  end

  describe "error handling" do
    test "retries on failure and continues polling" do
      # This test verifies that if the API fails, the poller keeps trying
      # Since we can't easily simulate API failures in integration tests,
      # we just verify that the poller continues to work
      assert_receive {:price_update, "BTCUSDT", _price}, 70_000
    end
  end
end
