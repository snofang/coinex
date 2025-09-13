defmodule Coinex.MinimumAmountTest do
  use ExUnit.Case, async: false
  alias Coinex.FuturesExchange

  setup do
    # Clean state for each test
    if Process.whereis(FuturesExchange) do
      GenServer.stop(FuturesExchange)
    end
    case FuturesExchange.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
    
    # Set predictable price
    FuturesExchange.set_current_price(Decimal.new("50000.0"))
    :ok
  end

  describe "Minimum Amount Tests" do
    test "accepts minimum amount of 0.0001 BTC for market orders" do
      # Should successfully create order with minimum amount
      {:ok, order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.0001")
      
      assert Decimal.equal?(order.amount, Decimal.new("0.0001"))
      assert order.status == "filled"
      
      # Should create position with correct margin
      positions = FuturesExchange.get_positions()
      assert length(positions) == 1
      
      position = hd(positions)
      expected_margin = Decimal.new("5.0")  # 0.0001 * 50000
      assert Decimal.equal?(position.margin_used, expected_margin)
    end

    test "accepts minimum amount of 0.0001 BTC for limit orders" do
      # Should successfully create limit order with minimum amount
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.0001", "48000.0")
      
      assert Decimal.equal?(order.amount, Decimal.new("0.0001"))
      assert order.status == "pending"
      
      # Fill the order
      FuturesExchange.set_current_price(Decimal.new("48000.0"))
      
      # Check position was created with correct margin
      positions = FuturesExchange.get_positions()
      assert length(positions) == 1
      
      position = hd(positions)
      expected_margin = Decimal.new("4.8")  # 0.0001 * 48000
      assert Decimal.equal?(position.margin_used, expected_margin)
    end

    test "balance reflects correct margin used for small amounts" do
      # Place small order
      {:ok, _order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.0001")
      
      balance = FuturesExchange.get_balance()
      expected_margin = Decimal.new("5.0")  # 0.0001 * 50000
      
      assert Decimal.equal?(balance.margin_used, expected_margin)
      
      # Available balance should be reduced by trading fee (5 * 0.0005 = 0.0025)
      # Also, margin is used so available balance = 10000 - margin_used - fee
      order_value = Decimal.new("5.0")  # 0.0001 * 50000
      fee = Decimal.mult(order_value, Decimal.new("0.0005"))  # 0.05% taker fee
      expected_available = Decimal.sub(Decimal.sub(Decimal.new("10000.0"), expected_margin), fee)  # 10000 - 5 - 0.0025
      assert Decimal.equal?(balance.available, expected_available)
    end

    test "handles amounts just above minimum correctly" do
      # Test amount slightly above minimum
      {:ok, order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.0002")
      
      assert Decimal.equal?(order.amount, Decimal.new("0.0002"))
      
      balance = FuturesExchange.get_balance()
      expected_margin = Decimal.new("10.0")  # 0.0002 * 50000
      
      assert Decimal.equal?(balance.margin_used, expected_margin)
    end
  end
end