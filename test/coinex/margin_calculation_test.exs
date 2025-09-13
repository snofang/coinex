defmodule Coinex.MarginCalculationTest do
  use ExUnit.Case, async: false
  alias Coinex.FuturesExchange

  setup do
    # Clean state for each test
    if Process.whereis(FuturesExchange) do
      GenServer.stop(FuturesExchange)
    end
    {:ok, _pid} = FuturesExchange.start_link([])
    
    # Set predictable price
    FuturesExchange.set_current_price(Decimal.new("50000.0"))
    :ok
  end

  describe "Margin Calculation Tests" do
    test "shows correct margin used after creating position via market order" do
      # Initial balance should show no margin used
      balance = FuturesExchange.get_balance()
      assert Decimal.equal?(balance.margin_used, Decimal.new("0"))

      # Place market order to create position
      {:ok, _order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.01")
      
      # Balance should now show margin used: 0.01 * 50000 = 500 USDT
      updated_balance = FuturesExchange.get_balance()
      expected_margin = Decimal.new("500.0")  # 0.01 * 50000
      
      assert Decimal.equal?(updated_balance.margin_used, expected_margin),
        "Expected margin used to be #{expected_margin}, got #{updated_balance.margin_used}"
    end

    test "shows correct margin used after limit order fills" do
      # Place limit order below current price
      {:ok, _order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.02", "48000.0")
      
      # No margin used yet (order is pending)
      balance = FuturesExchange.get_balance()
      assert Decimal.equal?(balance.margin_used, Decimal.new("0"))
      
      # Set price to fill the order
      FuturesExchange.set_current_price(Decimal.new("48000.0"))
      
      # Now margin should be used: 0.02 * 48000 = 960 USDT
      updated_balance = FuturesExchange.get_balance()
      expected_margin = Decimal.new("960.0")  # 0.02 * 48000
      
      assert Decimal.equal?(updated_balance.margin_used, expected_margin),
        "Expected margin used to be #{expected_margin}, got #{updated_balance.margin_used}"
    end

    test "aggregates margin from multiple positions" do
      # Create first position
      {:ok, _order1} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.01")
      balance1 = FuturesExchange.get_balance()
      expected_margin1 = Decimal.new("500.0")  # 0.01 * 50000
      
      assert Decimal.equal?(balance1.margin_used, expected_margin1)
      
      # Create second position
      {:ok, _order2} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.015")
      balance2 = FuturesExchange.get_balance()
      expected_margin2 = Decimal.new("1250.0")  # 0.025 * 50000 (aggregated)
      
      assert Decimal.equal?(balance2.margin_used, expected_margin2),
        "Expected total margin used to be #{expected_margin2}, got #{balance2.margin_used}"
    end

    test "reduces margin when position is reduced" do
      # Create position
      {:ok, _order1} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.02")
      balance1 = FuturesExchange.get_balance()
      expected_margin1 = Decimal.new("1000.0")  # 0.02 * 50000
      
      assert Decimal.equal?(balance1.margin_used, expected_margin1)
      
      # Reduce position by selling part of it
      {:ok, _order2} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.01")
      balance2 = FuturesExchange.get_balance()
      expected_margin2 = Decimal.new("500.0")  # 0.01 * 50000 (remaining)
      
      assert Decimal.equal?(balance2.margin_used, expected_margin2),
        "Expected reduced margin used to be #{expected_margin2}, got #{balance2.margin_used}"
    end

    test "shows zero margin when all positions are closed" do
      # Create and close position
      {:ok, _order1} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.01")
      {:ok, _order2} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.01")
      
      balance = FuturesExchange.get_balance()
      assert Decimal.equal?(balance.margin_used, Decimal.new("0")),
        "Expected no margin used after closing position, got #{balance.margin_used}"
    end

    test "calculates unrealized PnL correctly in balance" do
      # Create position at 50000
      {:ok, _order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.01")
      
      # Change price to create PnL
      FuturesExchange.set_current_price(Decimal.new("51000.0"))
      
      balance = FuturesExchange.get_balance()
      expected_pnl = Decimal.new("10.0")  # 0.01 * (51000 - 50000)
      
      assert Decimal.equal?(balance.unrealized_pnl, expected_pnl),
        "Expected unrealized PnL to be #{expected_pnl}, got #{balance.unrealized_pnl}"
      
      # Total balance should include PnL
      expected_total = Decimal.add(Decimal.new("9500.0"), expected_pnl)  # 10000 - 500 (used) + 10 (PnL)
      assert Decimal.equal?(balance.total, expected_total),
        "Expected total balance to be #{expected_total}, got #{balance.total}"
    end
  end
end