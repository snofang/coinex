defmodule Coinex.MinimumAmountValidationTest do
  use ExUnit.Case, async: false
  alias Coinex.FuturesExchange

  setup do
    # Ensure the GenServer is running
    case Process.whereis(FuturesExchange) do
      nil ->
        {:ok, _pid} = FuturesExchange.start_link([])

      _pid ->
        :ok
    end

    # Reset state to ensure clean slate for each test
    FuturesExchange.reset_state()

    # Set predictable price
    FuturesExchange.set_current_price(Decimal.new("50000.0"))
    :ok
  end

  describe "Minimum Amount Validation" do
    test "rejects market orders below minimum amount" do
      # Should reject orders below 0.0001 BTC
      {:error, reason} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.00009")
      assert reason == "Amount must be at least 0.0001 BTC"

      {:error, reason} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.00005")
      assert reason == "Amount must be at least 0.0001 BTC"
    end

    test "rejects limit orders below minimum amount" do
      # Should reject limit orders below 0.0001 BTC
      {:error, reason} =
        FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.00009", "50000.0")

      assert reason == "Amount must be at least 0.0001 BTC"

      {:error, reason} =
        FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.00005", "50000.0")

      assert reason == "Amount must be at least 0.0001 BTC"
    end

    test "accepts orders at exactly the minimum amount" do
      # Should accept orders exactly at 0.0001 BTC
      {:ok, market_order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.0001")
      assert Decimal.equal?(market_order.amount, Decimal.new("0.0001"))
      assert market_order.status == "filled"

      {:ok, limit_order} =
        FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.0001", "48000.0")

      assert Decimal.equal?(limit_order.amount, Decimal.new("0.0001"))
      assert limit_order.status == "pending"
    end

    test "accepts orders above the minimum amount" do
      # Should accept orders above 0.0001 BTC
      {:ok, order1} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.0002")
      assert Decimal.equal?(order1.amount, Decimal.new("0.0002"))

      {:ok, order2} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.001", "48000.0")
      assert Decimal.equal?(order2.amount, Decimal.new("0.001"))
    end

    test "validates very small rejected amounts" do
      # Test various small amounts that should be rejected
      invalid_amounts = ["0.00001", "0.000001", "0.00009999", "0"]

      for amount <- invalid_amounts do
        {:error, reason} = FuturesExchange.submit_market_order("BTCUSDT", "buy", amount)

        if amount == "0" do
          assert reason == "Amount must be positive"
        else
          assert reason == "Amount must be at least 0.0001 BTC"
        end
      end
    end

    test "validates string and number inputs correctly" do
      # Test both string and number inputs
      {:error, reason1} = FuturesExchange.submit_market_order("BTCUSDT", "buy", 0.00009)
      assert reason1 == "Amount must be at least 0.0001 BTC"

      {:ok, order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.0001")
      assert Decimal.equal?(order.amount, Decimal.new("0.0001"))
    end

    test "ensures no positions or balance changes for rejected orders" do
      # Initial state
      initial_balance = FuturesExchange.get_balance()
      initial_positions = FuturesExchange.get_positions()
      initial_orders = FuturesExchange.get_orders()

      # Try to place invalid order
      {:error, _reason} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.00005")

      # State should remain unchanged
      assert FuturesExchange.get_balance() == initial_balance
      assert FuturesExchange.get_positions() == initial_positions
      assert FuturesExchange.get_orders() == initial_orders
    end
  end
end
