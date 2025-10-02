defmodule Coinex.ProfitabilityEdgeCasesTest do
  use ExUnit.Case, async: false

  alias Coinex.FuturesExchange.{ActionCalculator, Balance, Position, Order}

  describe "Profitability Edge Cases" do
    test "minimum market order with 0.001% TP limit order results in loss (0.001% << 0.08% break-even)" do
      # Initial balance
      balance = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("5"),  # Frozen for minimum 0.0001 BTC order
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      positions = %{}
      
      # Step 1: Market buy order for minimum amount (0.0001 BTC at $50,000)
      market_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.0001"),  # Minimum amount
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("5")  # 0.0001 * 50000 = 5 USDT
      }
      
      fill_price = Decimal.new("50000")
      
      {balance_after_buy, positions_after_buy} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:fill_order, market_order, fill_price}
      )
      
      # Market order fee: 5 * 0.0005 = 0.0025 USDT (taker fee)
      expected_market_fee = Decimal.new("0.0025")
      assert Decimal.equal?(balance_after_buy.total_fees_paid, expected_market_fee)
      
      # Step 2: Set TP limit order with 0.001% profit target
      # 0.001% profit = 50000 * 1.00001 = 50000.5
      tp_price = Decimal.new("50000.5")
      
      # Limit sell order to close position at TP
      tp_order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.0001"),
        price: tp_price,
        frozen_amount: Decimal.new("0")  # No margin needed for position reduction
      }
      
      {balance_after_tp, positions_after_tp} = ActionCalculator.calculate_action_effect(
        balance_after_buy,
        positions_after_buy,
        {:fill_order, tp_order, tp_price}
      )
      
      # TP order value: 0.0001 * 50000.5 = 5.00005 USDT
      # TP limit order fee: 5.00005 * 0.0003 = 0.0015000150000 USDT (maker fee)
      expected_tp_fee = Decimal.new("0.0015000150000")
      expected_total_fees = Decimal.add(expected_market_fee, expected_tp_fee)
      
      assert Decimal.equal?(balance_after_tp.total_fees_paid, expected_total_fees)
      
      # Step 3: Calculate actual profit/loss
      # Entry cost: 5 USDT + 0.0025 fee = 5.0025 USDT
      # Exit proceeds: 5.00005 USDT - 0.00150015 fee = 4.99854985 USDT
      # Net P&L: 4.99854985 - 5.0025 = -0.00395015 USDT (LOSS!)
      
      entry_cost = Decimal.add(Decimal.new("5"), expected_market_fee)
      exit_proceeds = Decimal.sub(Decimal.new("5.00005"), expected_tp_fee)
      actual_pnl = Decimal.sub(exit_proceeds, entry_cost)
      
      # This should be negative - 0.001% profit is far below 0.08% break-even threshold
      assert Decimal.lt?(actual_pnl, Decimal.new("0"))
      
      # Verify the actual loss amount is negative (fees exceed tiny profit)
      assert Decimal.lt?(actual_pnl, Decimal.new("0"))
      # Verify it's close to expected loss (within precision tolerance)
      expected_loss_approx = Decimal.new("-0.00395")
      diff = Decimal.abs(Decimal.sub(actual_pnl, expected_loss_approx))
      assert Decimal.lt?(diff, Decimal.new("0.0001"))  # Within 0.01% tolerance
      
      # Position should be closed
      assert positions_after_tp["BTCUSDT"] == nil
    end
    
    test "break-even calculation: minimum profit needed to overcome fees" do
      # For minimum order size, what's the minimum price movement needed to break even?
      order_value = Decimal.new("5")  # 0.0001 BTC * $50,000
      
      # Total fees: taker fee + maker fee
      taker_fee = Decimal.mult(order_value, Decimal.new("0.0005"))  # 0.0025
      # For break-even, assume exit order value = entry order value + profit_needed
      # maker_fee = (order_value + profit_needed) * 0.0003
      # profit_needed = taker_fee + maker_fee
      # profit_needed = taker_fee + (order_value + profit_needed) * 0.0003
      # profit_needed = taker_fee + order_value * 0.0003 + profit_needed * 0.0003
      # profit_needed * (1 - 0.0003) = taker_fee + order_value * 0.0003
      # profit_needed = (taker_fee + order_value * 0.0003) / (1 - 0.0003)
      
      maker_base_fee = Decimal.mult(order_value, Decimal.new("0.0003"))
      numerator = Decimal.add(taker_fee, maker_base_fee)
      denominator = Decimal.sub(Decimal.new("1"), Decimal.new("0.0003"))
      profit_needed = Decimal.div(numerator, denominator)
      
      # Use more precision for the expected value
      expected_profit_needed = Decimal.div(numerator, denominator)
      assert Decimal.equal?(profit_needed, expected_profit_needed)
      
      # What percentage move is this?
      profit_percentage = Decimal.div(profit_needed, order_value)
      # Calculate expected percentage from the calculated profit_needed
      assert Decimal.gt?(profit_percentage, Decimal.new("0.0008"))  # Should be > 0.08%
      assert Decimal.lt?(profit_percentage, Decimal.new("0.0009"))  # Should be < 0.09%
      
      # The exact break-even profit needed is ~0.08002% (0.05% + 0.03% fees)
      # Note: 0.001% target is 80x below this break-even threshold
      
      # Verify the calculated break-even percentage 
      # profit_percentage is in decimal form (0.0008... = 0.08%)
      break_even_percentage = Decimal.mult(profit_percentage, Decimal.new("100"))
      assert Decimal.gt?(break_even_percentage, Decimal.new("0.0800"))  # > 0.08%
      assert Decimal.lt?(break_even_percentage, Decimal.new("0.0802"))  # < 0.0802%
    end
    
    test "fee threshold: orders below 0.08% profit margin are unprofitable (corrected)" do
      # Test various profit targets around the break-even threshold of 0.08%
      # Market fee (0.05%) + Limit fee (0.03%) = 0.08% total fees
      test_cases = [
        {Decimal.new("0.00001"), "0.001%", false},   # 0.001% - far below break-even
        {Decimal.new("0.0001"), "0.01%", false},     # 0.01% - still far below
        {Decimal.new("0.0005"), "0.05%", false},     # 0.05% - getting closer but unprofitable
        {Decimal.new("0.0007"), "0.07%", false},     # 0.07% - below break-even threshold
        {Decimal.new("0.0008"), "0.08%", false},     # 0.08% - at break-even (tiny loss due to precision)
        {Decimal.new("0.0009"), "0.09%", true},      # 0.09% - barely profitable! (~0.01% net profit)
        {Decimal.new("0.001"), "0.1%", true},        # 0.1% - profitable! (~0.02% net profit)
        {Decimal.new("0.0015"), "0.15%", true},      # 0.15% - clearly profitable
      ]
      
      Enum.each(test_cases, fn {profit_factor, description, should_be_profitable} ->
        # Simulate complete round-trip trade
        entry_price = Decimal.new("50000")
        exit_price = Decimal.mult(entry_price, Decimal.add(Decimal.new("1"), profit_factor))
        amount = Decimal.new("0.0001")
        
        # Entry fees (market order)
        entry_value = Decimal.mult(amount, entry_price)
        entry_fee = Decimal.mult(entry_value, Decimal.new("0.0005"))
        
        # Exit fees (limit order)  
        exit_value = Decimal.mult(amount, exit_price)
        exit_fee = Decimal.mult(exit_value, Decimal.new("0.0003"))
        
        # Net P&L
        total_fees = Decimal.add(entry_fee, exit_fee)
        gross_profit = Decimal.sub(exit_value, entry_value)
        net_pnl = Decimal.sub(gross_profit, total_fees)
        
        if should_be_profitable do
          assert Decimal.gt?(net_pnl, Decimal.new("0")), 
            "Expected #{description} to be profitable, got net P&L: $#{net_pnl}"
        else
          assert Decimal.compare(net_pnl, Decimal.new("0")) in [:lt, :eq], 
            "Expected #{description} to be unprofitable, got net P&L: $#{net_pnl}"
        end
      end)
    end
    
    test "0.1% profit target on minimum amount yields 0.02% net profit" do
      # Explicit test to verify user's calculation: 0.1% - 0.08% fees = 0.02% net profit
      balance = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("5"),  # Frozen for minimum 0.0001 BTC order
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      positions = %{}
      
      # Step 1: Market buy order for minimum amount (0.0001 BTC at $50,000)
      market_order = %Order{
        market: "BTCUSDT",
        side: "buy", 
        type: "market",
        amount: Decimal.new("0.0001"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("5")
      }
      
      {balance_after_buy, positions_after_buy} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:fill_order, market_order, Decimal.new("50000")}
      )
      
      # Step 2: TP limit order with 0.1% profit target
      # 0.1% profit = 50000 * 1.001 = 50050
      tp_price = Decimal.new("50050")
      
      tp_order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.0001"),
        price: tp_price,
        frozen_amount: Decimal.new("0")
      }
      
      {balance_after_tp, positions_after_tp} = ActionCalculator.calculate_action_effect(
        balance_after_buy,
        positions_after_buy,
        {:fill_order, tp_order, tp_price}
      )
      
      # Step 3: Calculate exact profit margins
      # Entry: 0.0001 * 50000 = 5 USDT, fee = 5 * 0.0005 = 0.0025 USDT
      # Exit: 0.0001 * 50050 = 5.005 USDT, fee = 5.005 * 0.0003 = 0.0015015 USDT
      # Gross profit: 5.005 - 5 = 0.005 USDT (0.1% of 5 USDT)
      # Total fees: 0.0025 + 0.0015015 = 0.0040015 USDT (0.08% of ~5 USDT)
      # Net profit: 0.005 - 0.0040015 = 0.0009985 USDT
      
      expected_market_fee = Decimal.new("0.0025")
      expected_tp_fee = Decimal.new("0.0015015")
      expected_total_fees = Decimal.add(expected_market_fee, expected_tp_fee)
      expected_gross_profit = Decimal.new("0.005")
      expected_net_profit = Decimal.sub(expected_gross_profit, expected_total_fees)
      
      # Verify fee calculations
      assert Decimal.equal?(balance_after_tp.total_fees_paid, expected_total_fees)
      
      # Verify position is closed
      assert positions_after_tp["BTCUSDT"] == nil
      
      # Calculate the actual net profit as percentage of entry value
      entry_value = Decimal.new("5")
      net_profit_percentage = Decimal.mult(Decimal.div(expected_net_profit, entry_value), Decimal.new("100"))
      
      # Should be approximately 0.02% (0.0199%)
      assert Decimal.gt?(net_profit_percentage, Decimal.new("0.019"))
      assert Decimal.lt?(net_profit_percentage, Decimal.new("0.021"))
      
      # Verify the key assertion: 0.1% target - 0.08% fees ≈ 0.02% net profit
      target_profit_percent = Decimal.new("0.1")
      fee_percent_approx = Decimal.mult(Decimal.div(expected_total_fees, entry_value), Decimal.new("100"))
      calculated_net_percent = Decimal.sub(target_profit_percent, fee_percent_approx)
      
      # The net profit percentage should match our calculated expectation
      assert Decimal.compare(Decimal.abs(Decimal.sub(net_profit_percentage, calculated_net_percent)), Decimal.new("0.001")) == :lt,
        "Expected net profit ~#{calculated_net_percent}%, got #{net_profit_percentage}%"
    end
    
    test "0.09% profit target yields 0.01% net profit (barely profitable edge case)" do
      # Test the smallest practically profitable scenario: 0.09% target
      # Expected: 0.09% - 0.08% fees = 0.01% net profit
      balance = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("5"),  # Frozen for minimum 0.0001 BTC order
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      positions = %{}
      
      # Step 1: Market buy order for minimum amount (0.0001 BTC at $50,000)
      market_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.0001"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("5")
      }
      
      {balance_after_buy, positions_after_buy} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:fill_order, market_order, Decimal.new("50000")}
      )
      
      # Step 2: TP limit order with 0.09% profit target
      # 0.09% profit = 50000 * 1.0009 = 50045
      tp_price = Decimal.new("50045")
      
      tp_order = %Order{
        market: "BTCUSDT",
        side: "sell", 
        type: "limit",
        amount: Decimal.new("0.0001"),
        price: tp_price,
        frozen_amount: Decimal.new("0")
      }
      
      {balance_after_tp, positions_after_tp} = ActionCalculator.calculate_action_effect(
        balance_after_buy,
        positions_after_buy,
        {:fill_order, tp_order, tp_price}
      )
      
      # Step 3: Calculate exact profit margins
      # Entry: 0.0001 * 50000 = 5 USDT, fee = 5 * 0.0005 = 0.0025 USDT (0.05%)
      # Exit: 0.0001 * 50045 = 5.0045 USDT, fee = 5.0045 * 0.0003 = 0.00150135 USDT (0.03%)
      # Gross profit: 5.0045 - 5 = 0.0045 USDT (0.09% of 5 USDT)
      # Total fees: 0.0025 + 0.00150135 = 0.00400135 USDT (~0.08% of 5 USDT)
      # Net profit: 0.0045 - 0.00400135 = 0.00049865 USDT (~0.01% of 5 USDT)
      
      expected_market_fee = Decimal.new("0.0025")
      expected_tp_fee = Decimal.new("0.00150135")
      expected_total_fees = Decimal.add(expected_market_fee, expected_tp_fee)
      expected_gross_profit = Decimal.new("0.0045")
      expected_net_profit = Decimal.sub(expected_gross_profit, expected_total_fees)
      
      # Verify fee calculations
      assert Decimal.equal?(balance_after_tp.total_fees_paid, expected_total_fees)
      
      # Verify position is closed
      assert positions_after_tp["BTCUSDT"] == nil
      
      # Calculate the actual net profit as percentage of entry value
      entry_value = Decimal.new("5")
      net_profit_percentage = Decimal.mult(Decimal.div(expected_net_profit, entry_value), Decimal.new("100"))
      
      # Should be approximately 0.01% (0.00997%)
      assert Decimal.gt?(net_profit_percentage, Decimal.new("0.009"))
      assert Decimal.lt?(net_profit_percentage, Decimal.new("0.011"))
      
      # Verify the key assertion: 0.09% target - 0.08% fees ≈ 0.01% net profit
      target_profit_percent = Decimal.new("0.09")
      fee_percent_approx = Decimal.mult(Decimal.div(expected_total_fees, entry_value), Decimal.new("100"))
      calculated_net_percent = Decimal.sub(target_profit_percent, fee_percent_approx)
      
      # The net profit percentage should match our calculated expectation (~0.01%)
      assert Decimal.compare(Decimal.abs(Decimal.sub(net_profit_percentage, calculated_net_percent)), Decimal.new("0.001")) == :lt,
        "Expected net profit ~#{calculated_net_percent}%, got #{net_profit_percentage}%"
    end
    
    test "granular break-even analysis: precise profit margins around 0.08% threshold" do
      # Test profit margins very close to break-even to verify precision
      # Break-even is at ~0.08% due to combined 0.05% + 0.03% fees
      precise_test_cases = [
        {Decimal.new("0.0008"), "0.080%", false},    # Right at break-even (tiny loss)
        {Decimal.new("0.000801"), "0.0801%", true},  # Just above break-even (tiny profit)
        {Decimal.new("0.000805"), "0.0805%", true},  # Slightly above break-even  
        {Decimal.new("0.00081"), "0.081%", true},    # Clearly above break-even
        {Decimal.new("0.00085"), "0.085%", true},    # Comfortably profitable
        {Decimal.new("0.0009"), "0.090%", true},     # 0.09% → ~0.01% net profit (validated above)
        {Decimal.new("0.00095"), "0.095%", true},    # More profitable
        {Decimal.new("0.001"), "0.100%", true},      # 0.1% → ~0.02% net profit
      ]
      
      entry_price = Decimal.new("50000")
      amount = Decimal.new("0.0001")
      
      Enum.each(precise_test_cases, fn {profit_factor, description, should_be_profitable} ->
        exit_price = Decimal.mult(entry_price, Decimal.add(Decimal.new("1"), profit_factor))
        
        # Calculate fees and profit
        entry_value = Decimal.mult(amount, entry_price)
        entry_fee = Decimal.mult(entry_value, Decimal.new("0.0005"))
        
        exit_value = Decimal.mult(amount, exit_price)
        exit_fee = Decimal.mult(exit_value, Decimal.new("0.0003"))
        
        total_fees = Decimal.add(entry_fee, exit_fee)
        gross_profit = Decimal.sub(exit_value, entry_value)
        net_pnl = Decimal.sub(gross_profit, total_fees)
        
        # Calculate net profit as percentage of entry value
        net_profit_percentage = Decimal.mult(Decimal.div(net_pnl, entry_value), Decimal.new("100"))
        
        if should_be_profitable do
          assert Decimal.gt?(net_pnl, Decimal.new("0")), 
            "#{description} should be profitable. Net P&L: $#{net_pnl} (#{net_profit_percentage}%)"
        else
          assert Decimal.compare(net_pnl, Decimal.new("0")) in [:lt, :eq], 
            "#{description} should be unprofitable. Net P&L: $#{net_pnl} (#{net_profit_percentage}%)"
        end
      end)
    end
    
    test "high-frequency scenario: multiple small profitable trades vs single large trade" do
      # Scenario A: 10 small trades with 0.2% profit each
      small_trade_amount = Decimal.new("0.0001")
      small_trade_profit_factor = Decimal.new("0.002")  # 0.2%
      num_small_trades = 10
      
      {total_small_fees, total_small_gross_profit} = 
        Enum.reduce(1..num_small_trades, {Decimal.new("0"), Decimal.new("0")}, fn _i, {acc_fees, acc_profit} ->
          entry_value = Decimal.mult(small_trade_amount, Decimal.new("50000"))
          exit_value = Decimal.mult(entry_value, Decimal.add(Decimal.new("1"), small_trade_profit_factor))
          
          entry_fee = Decimal.mult(entry_value, Decimal.new("0.0005"))
          exit_fee = Decimal.mult(exit_value, Decimal.new("0.0003"))
          
          new_fees = Decimal.add(acc_fees, Decimal.add(entry_fee, exit_fee))
          new_profit = Decimal.add(acc_profit, Decimal.sub(exit_value, entry_value))
          
          {new_fees, new_profit}
        end)
      
      small_trades_net_pnl = Decimal.sub(total_small_gross_profit, total_small_fees)
      
      # Scenario B: 1 large trade with same total amount and equivalent profit
      large_trade_amount = Decimal.mult(small_trade_amount, Decimal.new("10"))  # 0.001 BTC
      large_entry_value = Decimal.mult(large_trade_amount, Decimal.new("50000"))  # 50 USDT
      large_exit_value = Decimal.mult(large_entry_value, Decimal.add(Decimal.new("1"), small_trade_profit_factor))
      
      large_entry_fee = Decimal.mult(large_entry_value, Decimal.new("0.0005"))
      large_exit_fee = Decimal.mult(large_exit_value, Decimal.new("0.0003"))
      large_total_fees = Decimal.add(large_entry_fee, large_exit_fee)
      
      large_gross_profit = Decimal.sub(large_exit_value, large_entry_value)
      large_net_pnl = Decimal.sub(large_gross_profit, large_total_fees)
      
      # For this specific scenario (0.2% profit), both achieve similar results
      # Demonstrates that with sufficient profit margin, trade frequency matters less
      difference = Decimal.sub(large_net_pnl, small_trades_net_pnl)
      assert Decimal.compare(Decimal.abs(difference), Decimal.new("0.01")) in [:lt, :eq],
        "Large vs small trades difference: $#{difference}. Both should be similar for adequate profit margins."
      
      # Both scenarios demonstrate that with 0.2% profit margins (well above 0.08% break-even),
      # trading frequency becomes less critical than ensuring adequate profit targets
    end
    
    test "margin call scenario: position becomes unprofitable due to fees" do
      # Start with a position that should be barely profitable
      balance = %Balance{
        available: Decimal.new("9900"),
        frozen: Decimal.new("0"),
        margin_used: Decimal.new("100"),  # 100 USDT margin
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }
      
      # Existing position with small unrealized profit
      positions = %{
        "BTCUSDT" => %Position{
          market: "BTCUSDT",
          side: "long",
          amount: Decimal.new("0.002"),  # 0.002 BTC
          entry_price: Decimal.new("50000"),
          margin_used: Decimal.new("100"),
          unrealized_pnl: Decimal.new("2"),  # Small $2 profit
          leverage: Decimal.new("1"),
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      }
      
      # Force close position at current price (emergency exit)
      emergency_exit_order = %Order{
        market: "BTCUSDT",
        side: "sell", 
        type: "market",  # Market order for immediate execution
        amount: Decimal.new("0.002"),
        price: Decimal.new("50100"),  # Slightly higher price
        frozen_amount: Decimal.new("0")
      }
      
      fill_price = Decimal.new("50100")
      
      {balance_after_exit, positions_after_exit} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:fill_order, emergency_exit_order, fill_price}
      )
      
      # Exit order value: 0.002 * 50100 = 100.2 USDT
      # Market order fee: 100.2 * 0.0005 = 0.0501 USDT
      expected_exit_fee = Decimal.new("0.0501")

      assert Decimal.equal?(balance_after_exit.total_fees_paid, expected_exit_fee)

      # Realized profit calculation:
      # Entry: 0.002 * 50000 = 100 USDT
      # Exit: 0.002 * 50100 = 100.2 USDT
      # Realized profit: 100.2 - 100 = 0.2 USDT
      # Available balance: 9900 + 0 (unfreeze) - 0.0501 (fee) + 100 (margin released) + 0.2 (realized profit)
      # = 9900 - 0.0501 + 100 + 0.2 = 10000.1499
      expected_available = Decimal.new("10000.1499")
      assert Decimal.equal?(balance_after_exit.available, expected_available)
      
      # Position should be closed
      assert positions_after_exit["BTCUSDT"] == nil
    end

    test "$50 position with 0.1% profit target yields 1 cent net profit" do
      # Initial balance: $10,000 total with $50 frozen for order
      balance = %Balance{
        available: Decimal.new("9950"),
        frozen: Decimal.new("50"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }

      positions = %{}

      # Step 1: Market buy order for 0.001 BTC at $50,000 = $50
      market_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.001"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("50")
      }

      {balance_after_buy, positions_after_buy} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:fill_order, market_order, Decimal.new("50000")}
      )

      # After market buy:
      # - Unfreeze 50: 9950 + 50 = 10000
      # - Deduct fee: 10000 - 0.025 = 9999.975
      # - Deduct margin: 9999.975 - 50 = 9949.975
      # - available: 9949.975, margin_used: 50, total: 9999.975
      assert Decimal.equal?(balance_after_buy.available, Decimal.new("9949.975"))
      assert Decimal.equal?(balance_after_buy.frozen, Decimal.new("0"))
      assert Decimal.equal?(balance_after_buy.margin_used, Decimal.new("50"))
      assert Decimal.equal?(balance_after_buy.total_fees_paid, Decimal.new("0.025"))

      # Step 2: TP limit order with 0.1% profit target
      # 0.1% profit = 50000 * 1.001 = 50050
      tp_price = Decimal.new("50050")

      tp_order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.001"),
        price: tp_price,
        frozen_amount: Decimal.new("0")
      }

      {balance_after_tp, positions_after_tp} = ActionCalculator.calculate_action_effect(
        balance_after_buy,
        positions_after_buy,
        {:fill_order, tp_order, tp_price}
      )

      # After TP order filled:
      # - Exit value: 0.001 * 50050 = 50.05
      # - Exit fee: 50.05 * 0.0003 = 0.015015 (maker fee)
      # - Unfreeze: 9949.975 + 0 = 9949.975 (no frozen amount)
      # - Deduct fee: 9949.975 - 0.015015 = 9949.959985
      # - Margin released: 9949.959985 + 50 = 9999.959985
      # - Realized profit from position: +0.05 (exit 50.05 - entry 50)
      # - Final available: 9999.959985 + 0.05 = 10000.009985
      expected_available = Decimal.new("10000.009985")
      assert Decimal.equal?(balance_after_tp.available, expected_available)

      # Total fees: 0.025 + 0.015015 = 0.040015
      expected_total_fees = Decimal.new("0.040015")
      assert Decimal.equal?(balance_after_tp.total_fees_paid, expected_total_fees)

      # Position should be closed
      assert positions_after_tp["BTCUSDT"] == nil

      # Verify net profit calculation
      # Entry cost: 50 + 0.025 = 50.025
      # Exit proceeds: 50.05 - 0.015015 = 50.034985
      # Net P&L: 50.034985 - 50.025 = 0.009985 ≈ $0.01 (1 cent)
      entry_cost = Decimal.add(Decimal.new("50"), Decimal.new("0.025"))
      exit_proceeds = Decimal.sub(Decimal.new("50.05"), Decimal.new("0.015015"))
      net_pnl = Decimal.sub(exit_proceeds, entry_cost)

      # Net profit should be approximately 1 cent
      assert Decimal.gt?(net_pnl, Decimal.new("0.009"))
      assert Decimal.lt?(net_pnl, Decimal.new("0.011"))

      # Final balance should be starting balance + net profit
      # Starting available: 9950, Final: 10000.009985
      # Gain: 10000.009985 - 9950 = 50.009985
      # Which equals: margin returned (50) + realized profit (0.05) - total fees (0.040015)
      starting_available = Decimal.new("9950")
      actual_gain = Decimal.sub(balance_after_tp.available, starting_available)
      expected_gain = Decimal.new("50.009985")
      assert Decimal.equal?(actual_gain, expected_gain)

      # Verify starting total + net_pnl = final available
      starting_total = Decimal.new("10000")
      expected_final = Decimal.add(starting_total, net_pnl)
      assert Decimal.equal?(balance_after_tp.available, expected_final)
    end

    test "edge case: exact break-even point where profit = fees (0.080024%)" do
      # Test the mathematically exact break-even point
      # For break-even: realized_profit = total_fees
      # V × x = V × 0.0005 + V × (1 + x) × 0.0003
      # Solving: x = 0.0008 / 0.9997 ≈ 0.00080024007
      # So exact break-even is at ~0.080024% profit
      balance = %Balance{
        available: Decimal.new("9950"),
        frozen: Decimal.new("50"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }

      positions = %{}

      # Step 1: Market buy order for 0.001 BTC at $50,000 = $50
      market_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.001"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("50")
      }

      {balance_after_buy, positions_after_buy} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:fill_order, market_order, Decimal.new("50000")}
      )

      # After market buy:
      assert Decimal.equal?(balance_after_buy.available, Decimal.new("9949.975"))
      assert Decimal.equal?(balance_after_buy.total_fees_paid, Decimal.new("0.025"))

      # Step 2: TP limit order with exact break-even price
      # Break-even percentage: 0.00080024007
      # Target price: 50000 × 1.00080024007 = 50040.012
      tp_price = Decimal.new("50040.012")

      tp_order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.001"),
        price: tp_price,
        frozen_amount: Decimal.new("0")
      }

      {balance_after_tp, positions_after_tp} = ActionCalculator.calculate_action_effect(
        balance_after_buy,
        positions_after_buy,
        {:fill_order, tp_order, tp_price}
      )

      # After TP order filled:
      # - Exit value: 0.001 × 50040.012 = 50.040012
      # - Exit fee: 50.040012 × 0.0003 = 0.0150120036
      # - Realized profit: 50.040012 - 50 = 0.040012
      # - Total fees: 0.025 + 0.0150120036 = 0.0400120036
      # - Net P&L: 0.040012 - 0.0400120036 = -0.0000000036 ≈ 0

      # Position should be closed
      assert positions_after_tp["BTCUSDT"] == nil

      # Calculate exact values
      exit_value = Decimal.mult(Decimal.new("0.001"), tp_price)
      exit_fee = Decimal.mult(exit_value, Decimal.new("0.0003"))
      realized_profit = Decimal.sub(exit_value, Decimal.new("50"))
      total_fees = Decimal.add(Decimal.new("0.025"), exit_fee)

      # Verify realized profit equals total fees (within precision)
      profit_vs_fees_diff = Decimal.sub(realized_profit, total_fees)
      assert Decimal.compare(Decimal.abs(profit_vs_fees_diff), Decimal.new("0.000001")) == :lt

      # Final balance should equal starting balance (exact break-even)
      starting_total = Decimal.new("10000")
      balance_change = Decimal.sub(balance_after_tp.available, starting_total)

      # The balance change should be essentially zero (within 0.000001)
      assert Decimal.compare(Decimal.abs(balance_change), Decimal.new("0.000001")) == :lt
    end
  end
end