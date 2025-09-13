defmodule Coinex.FrozenBalanceBugRegressionTest do
  use ExUnit.Case
  
  alias Coinex.FuturesExchange.{ActionCalculator, Balance, Position, Order}
  
  describe "Frozen Balance Bug Regression Tests" do
    setup do
      # Common setup: long position and initial balance
      balance = %Balance{
        available: Decimal.new("9000"),
        frozen: Decimal.new("0"),
        margin_used: Decimal.new("1000"),  # From existing position
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0")
      }
      
      positions = %{
        "BTCUSDT" => %Position{
          market: "BTCUSDT",
          side: "long",
          amount: Decimal.new("0.02"),  # 0.02 BTC long position
          entry_price: Decimal.new("50000"),
          margin_used: Decimal.new("1000"),
          unrealized_pnl: Decimal.new("0"),
          leverage: Decimal.new("1"),
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      }
      
      %{balance: balance, positions: positions}
    end
    
    test "scenario 1: simple position + single opposing order (should work)", %{balance: balance, positions: positions} do
      # Place a limit sell order that exceeds position (0.04 > 0.02)
      order = %Order{
        id: 1,
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.04"),  # Double the position
        price: Decimal.new("52000"),
        frozen_amount: Decimal.new("0")  # Will be calculated
      }
      
      # Calculate frozen amount (should be for excess: 0.02 * 52000 = 1040)
      frozen_amount = ActionCalculator.calculate_frozen_for_order(order, positions)
      order_with_frozen = %{order | frozen_amount: frozen_amount}
      
      # Place the order
      {balance_after_place, positions_after_place} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:place_order, order_with_frozen}
      )
      
      # Verify frozen amount is correct
      assert Decimal.equal?(frozen_amount, Decimal.new("1040"))  # 0.02 * 52000
      assert Decimal.equal?(balance_after_place.frozen, Decimal.new("1040"))
      
      # Cancel the order
      {balance_after_cancel, _} = ActionCalculator.calculate_action_effect(
        balance_after_place,
        positions_after_place,
        {:cancel_order, order_with_frozen}
      )
      
      # Verify frozen balance is back to zero
      assert Decimal.equal?(balance_after_cancel.frozen, Decimal.new("0"))
      assert Decimal.equal?(balance_after_cancel.available, balance.available)
    end
    
    test "scenario 2: position + multiple opposing orders (bug scenario)", %{balance: balance, positions: positions} do
      # This is the complex scenario that was causing the bug
      
      # First, place a large sell order (0.06 BTC)
      order1 = %Order{
        id: 1,
        market: "BTCUSDT", 
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.06"),  # 3x the position
        price: Decimal.new("52000"),
        frozen_amount: Decimal.new("0")
      }
      
      frozen1 = ActionCalculator.calculate_frozen_for_order(order1, positions)
      order1_with_frozen = %{order1 | frozen_amount: frozen1}
      
      {balance_after_order1, positions_after_order1} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:place_order, order1_with_frozen}
      )
      
      # Expected frozen for order1: (0.06 - 0.02) * 52000 = 0.04 * 52000 = 2080
      assert Decimal.equal?(frozen1, Decimal.new("2080"))
      assert Decimal.equal?(balance_after_order1.frozen, Decimal.new("2080"))
      
      # Now place a second sell order (0.04 BTC)
      order2 = %Order{
        id: 2,
        market: "BTCUSDT",
        side: "sell",
        type: "limit", 
        amount: Decimal.new("0.04"),  # 2x the position
        price: Decimal.new("52000"),
        frozen_amount: Decimal.new("0")
      }
      
      # Key insight: This calculation should be independent of order1!
      # It should calculate as if only the position exists, not considering order1
      frozen2 = ActionCalculator.calculate_frozen_for_order(order2, positions)
      order2_with_frozen = %{order2 | frozen_amount: frozen2}
      
      {balance_after_order2, positions_after_order2} = ActionCalculator.calculate_action_effect(
        balance_after_order1,
        positions_after_order1,
        {:place_order, order2_with_frozen}
      )
      
      # Expected frozen for order2: (0.04 - 0.02) * 52000 = 0.02 * 52000 = 1040
      assert Decimal.equal?(frozen2, Decimal.new("1040"))
      # Total frozen should be 2080 + 1040 = 3120
      assert Decimal.equal?(balance_after_order2.frozen, Decimal.new("3120"))
      
      # Now cancel order1 (the larger order)
      {balance_after_cancel1, positions_after_cancel1} = ActionCalculator.calculate_action_effect(
        balance_after_order2,
        positions_after_order2,
        {:cancel_order, order1_with_frozen}
      )
      
      # After cancelling order1, frozen should be just order2's amount: 1040
      assert Decimal.equal?(balance_after_cancel1.frozen, Decimal.new("1040"))
      
      # Cancel order2
      {balance_final, _} = ActionCalculator.calculate_action_effect(
        balance_after_cancel1,
        positions_after_cancel1,
        {:cancel_order, order2_with_frozen}
      )
      
      # Final frozen should be zero
      assert Decimal.equal?(balance_final.frozen, Decimal.new("0"))
      
      # Available balance should be back to original
      assert Decimal.equal?(balance_final.available, balance.available)
    end
    
    test "scenario 3: mixed same-side and opposite-side orders", %{balance: balance, positions: positions} do
      # Place a buy order (same side as long position)
      buy_order = %Order{
        id: 1,
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.01"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("0")
      }
      
      frozen_buy = ActionCalculator.calculate_frozen_for_order(buy_order, positions)
      buy_order_with_frozen = %{buy_order | frozen_amount: frozen_buy}
      
      {balance_after_buy, positions_after_buy} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:place_order, buy_order_with_frozen}
      )
      
      # Buy order should freeze full amount: 0.01 * 50000 = 500
      assert Decimal.equal?(frozen_buy, Decimal.new("500"))
      assert Decimal.equal?(balance_after_buy.frozen, Decimal.new("500"))
      
      # Place a sell order (opposite side)
      sell_order = %Order{
        id: 2,
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.03"),
        price: Decimal.new("51000"),
        frozen_amount: Decimal.new("0")
      }
      
      # This should calculate based on original position (0.02), not considering pending buy order
      frozen_sell = ActionCalculator.calculate_frozen_for_order(sell_order, positions)
      sell_order_with_frozen = %{sell_order | frozen_amount: frozen_sell}
      
      {balance_after_sell, positions_after_sell} = ActionCalculator.calculate_action_effect(
        balance_after_buy,
        positions_after_buy,
        {:place_order, sell_order_with_frozen}
      )
      
      # Sell order frozen: (0.03 - 0.02) * 51000 = 0.01 * 51000 = 510
      assert Decimal.equal?(frozen_sell, Decimal.new("510"))
      # Total frozen: 500 + 510 = 1010
      assert Decimal.equal?(balance_after_sell.frozen, Decimal.new("1010"))
      
      # Cancel buy order first
      {balance_after_cancel_buy, positions_after_cancel_buy} = ActionCalculator.calculate_action_effect(
        balance_after_sell,
        positions_after_sell,
        {:cancel_order, buy_order_with_frozen}
      )
      
      # Should have only sell order frozen: 510
      assert Decimal.equal?(balance_after_cancel_buy.frozen, Decimal.new("510"))
      
      # Cancel sell order
      {balance_final, _} = ActionCalculator.calculate_action_effect(
        balance_after_cancel_buy,
        positions_after_cancel_buy,
        {:cancel_order, sell_order_with_frozen}
      )
      
      # Should be back to zero frozen
      assert Decimal.equal?(balance_final.frozen, Decimal.new("0"))
      assert Decimal.equal?(balance_final.available, balance.available)
    end
    
    test "scenario 4: short position with multiple buy orders", %{balance: balance} do
      # Setup with short position instead
      short_positions = %{
        "BTCUSDT" => %Position{
          market: "BTCUSDT",
          side: "short",
          amount: Decimal.new("0.02"),
          entry_price: Decimal.new("50000"),
          margin_used: Decimal.new("1000"),
          unrealized_pnl: Decimal.new("0"),
          leverage: Decimal.new("1"),
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      }
      
      # Place two buy orders (opposite side to short)
      order1 = %Order{
        id: 1,
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.05"),  # Exceeds position
        price: Decimal.new("49000"),
        frozen_amount: Decimal.new("0")
      }
      
      frozen1 = ActionCalculator.calculate_frozen_for_order(order1, short_positions)
      order1_with_frozen = %{order1 | frozen_amount: frozen1}
      
      {balance_after_order1, _} = ActionCalculator.calculate_action_effect(
        balance,
        short_positions,
        {:place_order, order1_with_frozen}
      )
      
      # Frozen for excess: (0.05 - 0.02) * 49000 = 0.03 * 49000 = 1470
      assert Decimal.equal?(frozen1, Decimal.new("1470"))
      
      order2 = %Order{
        id: 2,
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.03"),
        price: Decimal.new("49000"),
        frozen_amount: Decimal.new("0")
      }
      
      frozen2 = ActionCalculator.calculate_frozen_for_order(order2, short_positions)
      order2_with_frozen = %{order2 | frozen_amount: frozen2}
      
      {balance_after_order2, _} = ActionCalculator.calculate_action_effect(
        balance_after_order1,
        short_positions,
        {:place_order, order2_with_frozen}
      )
      
      # Frozen for excess: (0.03 - 0.02) * 49000 = 0.01 * 49000 = 490
      assert Decimal.equal?(frozen2, Decimal.new("490"))
      # Total: 1470 + 490 = 1960
      assert Decimal.equal?(balance_after_order2.frozen, Decimal.new("1960"))
      
      # Cancel first order
      {balance_after_cancel1, _} = ActionCalculator.calculate_action_effect(
        balance_after_order2,
        short_positions,
        {:cancel_order, order1_with_frozen}
      )
      
      # Should have only second order frozen: 490
      assert Decimal.equal?(balance_after_cancel1.frozen, Decimal.new("490"))
      
      # Cancel second order  
      {balance_final, _} = ActionCalculator.calculate_action_effect(
        balance_after_cancel1,
        short_positions,
        {:cancel_order, order2_with_frozen}
      )
      
      # Should be zero
      assert Decimal.equal?(balance_final.frozen, Decimal.new("0"))
    end
  end
  
  describe "Order-independence verification" do
    test "frozen calculation doesn't depend on other pending orders" do
      positions = %{
        "BTCUSDT" => %Position{
          market: "BTCUSDT",
          side: "long", 
          amount: Decimal.new("0.01"),
          entry_price: Decimal.new("50000"),
          margin_used: Decimal.new("500"),
          unrealized_pnl: Decimal.new("0"),
          leverage: Decimal.new("1"),
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      }
      
      # Create a test order
      order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.03"),
        price: Decimal.new("51000"),
        frozen_amount: Decimal.new("0")
      }
      
      # Calculate frozen amount - should be same regardless of other orders
      frozen1 = ActionCalculator.calculate_frozen_for_order(order, positions)
      
      # Expected: (0.03 - 0.01) * 51000 = 0.02 * 51000 = 1020
      assert Decimal.equal?(frozen1, Decimal.new("1020"))
      
      # The key property: this calculation should never change regardless of 
      # what other orders exist in the system. It only depends on position vs this order.
    end
  end
end