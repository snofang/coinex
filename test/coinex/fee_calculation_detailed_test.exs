defmodule Coinex.FeeCalculationDetailedTest do
  use ExUnit.Case
  
  alias Coinex.FuturesExchange.{ActionCalculator, Balance, Position, Order}
  
  describe "Detailed Fee Calculation in calculate_action_effect" do
    test "verifies exact taker fee calculation (0.05%) with different order values" do
      # Test Case 1: Small order
      balance1 = %Balance{
        available: Decimal.new("1000"),
        frozen: Decimal.new("50"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("1000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      market_order1 = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.001"),  # 0.001 BTC
        price: Decimal.new("50000"),   # At $50,000
        frozen_amount: Decimal.new("50")
      }
      
      {result1, _} = ActionCalculator.calculate_action_effect(
        balance1, %{}, {:fill_order, market_order1, Decimal.new("50000")}
      )
      
      # Expected: 0.001 * 50000 * 0.0005 = 0.025 USDT
      expected_fee1 = Decimal.new("0.025")
      assert Decimal.equal?(result1.total_fees_paid, expected_fee1)
      
      # Test Case 2: Medium order
      balance2 = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("2000"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      market_order2 = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.04"),   # 0.04 BTC
        price: Decimal.new("50000"),   # At $50,000
        frozen_amount: Decimal.new("2000")
      }
      
      {result2, _} = ActionCalculator.calculate_action_effect(
        balance2, %{}, {:fill_order, market_order2, Decimal.new("50000")}
      )
      
      # Expected: 0.04 * 50000 * 0.0005 = 1.0 USDT
      expected_fee2 = Decimal.new("1.0")
      assert Decimal.equal?(result2.total_fees_paid, expected_fee2)
      
      # Test Case 3: High-value order with different price
      balance3 = %Balance{
        available: Decimal.new("100000"),
        frozen: Decimal.new("7200"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("100000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      market_order3 = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "market",
        amount: Decimal.new("0.1"),    # 0.1 BTC
        price: Decimal.new("72000"),   # At $72,000
        frozen_amount: Decimal.new("7200")
      }
      
      {result3, _} = ActionCalculator.calculate_action_effect(
        balance3, %{}, {:fill_order, market_order3, Decimal.new("72000")}
      )
      
      # Expected: 0.1 * 72000 * 0.0005 = 3.6 USDT
      expected_fee3 = Decimal.new("3.6")
      assert Decimal.equal?(result3.total_fees_paid, expected_fee3)
    end
    
    test "verifies exact maker fee calculation (0.03%) with different order values" do
      # Test Case 1: Small limit order
      balance1 = %Balance{
        available: Decimal.new("1000"),
        frozen: Decimal.new("50"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("1000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      limit_order1 = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.001"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("50")
      }
      
      {result1, _} = ActionCalculator.calculate_action_effect(
        balance1, %{}, {:fill_order, limit_order1, Decimal.new("50000")}
      )
      
      # Expected: 0.001 * 50000 * 0.0003 = 0.015 USDT
      expected_fee1 = Decimal.new("0.015")
      assert Decimal.equal?(result1.total_fees_paid, expected_fee1)
      
      # Test Case 2: Larger limit order
      balance2 = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("1500"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      limit_order2 = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.03"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("1500")
      }
      
      {result2, _} = ActionCalculator.calculate_action_effect(
        balance2, %{}, {:fill_order, limit_order2, Decimal.new("50000")}
      )
      
      # Expected: 0.03 * 50000 * 0.0003 = 0.45 USDT
      expected_fee2 = Decimal.new("0.45")
      assert Decimal.equal?(result2.total_fees_paid, expected_fee2)
    end
    
    test "verifies fee calculation with different fill prices vs order prices" do
      balance = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("500"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      # Limit order at $50,000 but filled at $51,000 (better price)
      limit_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.01"),
        price: Decimal.new("50000"),    # Order price
        frozen_amount: Decimal.new("500")
      }
      
      fill_price = Decimal.new("51000")  # Better fill price
      
      {result, _} = ActionCalculator.calculate_action_effect(
        balance, %{}, {:fill_order, limit_order, fill_price}
      )
      
      # Fee should be calculated based on FILL PRICE, not order price
      # Expected: 0.01 * 51000 * 0.0003 = 0.153 USDT
      expected_fee = Decimal.new("0.153")
      assert Decimal.equal?(result.total_fees_paid, expected_fee)
    end
    
    test "verifies cumulative fee calculation across multiple orders" do
      initial_balance = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("0"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("1.5")  # Starting with existing fees
      }
      
      # First order: Market order
      market_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.02"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("1000")
      }
      
      {balance_after_first, positions_after_first} = ActionCalculator.calculate_action_effect(
        initial_balance, %{}, {:fill_order, market_order, Decimal.new("50000")}
      )
      
      # Expected fee: 0.02 * 50000 * 0.0005 = 0.5 USDT
      # Total fees: 1.5 + 0.5 = 2.0 USDT
      expected_after_first = Decimal.new("2.0")
      assert Decimal.equal?(balance_after_first.total_fees_paid, expected_after_first)
      
      # Second order: Limit order (sell part of position)
      limit_order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.01"),
        price: Decimal.new("52000"),
        frozen_amount: Decimal.new("0")  # Position-reducing order
      }
      
      {balance_final, _} = ActionCalculator.calculate_action_effect(
        balance_after_first, positions_after_first, {:fill_order, limit_order, Decimal.new("52000")}
      )
      
      # Expected fee: 0.01 * 52000 * 0.0003 = 0.156 USDT
      # Total fees: 2.0 + 0.156 = 2.156 USDT
      expected_final = Decimal.new("2.156")
      assert Decimal.equal?(balance_final.total_fees_paid, expected_final)
    end
    
    test "verifies fee calculation with decimal precision" do
      balance = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("33.33"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      # Order with precise decimal amounts
      precise_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.00123456"),  # Precise amount
        price: Decimal.new("45678.9876"),   # Precise price
        frozen_amount: Decimal.new("56.41")
      }
      
      fill_price = Decimal.new("45678.9876")
      
      {result, _} = ActionCalculator.calculate_action_effect(
        balance, %{}, {:fill_order, precise_order, fill_price}
      )
      
      # Expected calculation:
      # Order value: 0.00123456 * 45678.9876 = 56.393450931456
      # Taker fee: 56.393450931456 * 0.0005 = 0.0281967254657280
      expected_fee = Decimal.new("0.0281967254657280")
      assert Decimal.equal?(result.total_fees_paid, expected_fee)
    end
    
    test "verifies fee rates are applied correctly based on order type" do
      balance = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("1000"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      # Same order details, different types
      amount = Decimal.new("0.02")
      price = Decimal.new("50000")
      frozen_amount = Decimal.new("1000")
      
      # Market order (taker)
      market_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: amount,
        price: price,
        frozen_amount: frozen_amount
      }
      
      {result_market, _} = ActionCalculator.calculate_action_effect(
        balance, %{}, {:fill_order, market_order, price}
      )
      
      # Limit order (maker)
      limit_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: amount,
        price: price,
        frozen_amount: frozen_amount
      }
      
      {result_limit, _} = ActionCalculator.calculate_action_effect(
        balance, %{}, {:fill_order, limit_order, price}
      )
      
      # Market order fee: 0.02 * 50000 * 0.0005 = 0.5 USDT
      expected_taker_fee = Decimal.new("0.5")
      assert Decimal.equal?(result_market.total_fees_paid, expected_taker_fee)
      
      # Limit order fee: 0.02 * 50000 * 0.0003 = 0.3 USDT
      expected_maker_fee = Decimal.new("0.3")
      assert Decimal.equal?(result_limit.total_fees_paid, expected_maker_fee)
      
      # Verify different rates applied
      assert Decimal.compare(result_market.total_fees_paid, result_limit.total_fees_paid) == :gt
    end
  end
end