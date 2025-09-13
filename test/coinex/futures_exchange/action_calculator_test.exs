defmodule Coinex.FuturesExchange.ActionCalculatorTest do
  use ExUnit.Case
  
  alias Coinex.FuturesExchange.{ActionCalculator, Balance, Position, Order}
  
  describe "calculate_frozen_for_order/2" do
    test "with no existing position, freezes full order value" do
      order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.001"),
        price: Decimal.new("50000")
      }
      
      positions = %{}
      
      frozen = ActionCalculator.calculate_frozen_for_order(order, positions)
      
      # Should freeze full amount: 0.001 * 50000 = 50
      assert Decimal.equal?(frozen, Decimal.new("50"))
    end
    
    test "with long position, buy order (same side) freezes full order value" do
      order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.0005"),
        price: Decimal.new("50000")
      }
      
      positions = %{
        "BTCUSDT" => %Position{
          side: "long",
          amount: Decimal.new("0.001")
        }
      }
      
      frozen = ActionCalculator.calculate_frozen_for_order(order, positions)
      
      # Should freeze full amount: 0.0005 * 50000 = 25
      assert Decimal.equal?(frozen, Decimal.new("25"))
    end
    
    test "with long position, sell order within position size freezes zero" do
      order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.0005"),  # Less than position
        price: Decimal.new("50000")
      }
      
      positions = %{
        "BTCUSDT" => %Position{
          side: "long",
          amount: Decimal.new("0.001")  # Position is larger
        }
      }
      
      frozen = ActionCalculator.calculate_frozen_for_order(order, positions)
      
      # Should freeze zero - order reduces existing position
      assert Decimal.equal?(frozen, Decimal.new("0"))
    end
    
    test "with long position, sell order exceeding position freezes excess" do
      order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.002"),   # More than position
        price: Decimal.new("50000")
      }
      
      positions = %{
        "BTCUSDT" => %Position{
          side: "long",
          amount: Decimal.new("0.001")  # Position is smaller
        }
      }
      
      frozen = ActionCalculator.calculate_frozen_for_order(order, positions)
      
      # Should freeze excess: (0.002 - 0.001) * 50000 = 50
      assert Decimal.equal?(frozen, Decimal.new("50"))
    end
    
    test "with short position, buy order within position size freezes zero" do
      order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.0005"),
        price: Decimal.new("50000")
      }
      
      positions = %{
        "BTCUSDT" => %Position{
          side: "short",
          amount: Decimal.new("0.001")
        }
      }
      
      frozen = ActionCalculator.calculate_frozen_for_order(order, positions)
      
      assert Decimal.equal?(frozen, Decimal.new("0"))
    end
    
    test "with short position, buy order exceeding position freezes excess" do
      order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.002"),
        price: Decimal.new("50000")
      }
      
      positions = %{
        "BTCUSDT" => %Position{
          side: "short",
          amount: Decimal.new("0.001")
        }
      }
      
      frozen = ActionCalculator.calculate_frozen_for_order(order, positions)
      
      # Should freeze excess: (0.002 - 0.001) * 50000 = 50
      assert Decimal.equal?(frozen, Decimal.new("50"))
    end
  end
  
  describe "calculate_action_effect/3 - place_order" do
    test "places order and updates balance correctly" do
      balance = %Balance{
        available: Decimal.new("1000"),
        frozen: Decimal.new("0"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("1000"),
        unrealized_pnl: Decimal.new("0")
      }
      
      positions = %{}
      
      order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.001"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("50")
      }
      
      {new_balance, new_positions} = ActionCalculator.calculate_action_effect(
        balance, 
        positions, 
        {:place_order, order}
      )
      
      assert Decimal.equal?(new_balance.available, Decimal.new("950"))  # 1000 - 50
      assert Decimal.equal?(new_balance.frozen, Decimal.new("50"))
      assert new_positions == positions  # Positions unchanged on order placement
    end
  end
  
  describe "calculate_action_effect/3 - cancel_order" do
    test "cancels order and unfreezes funds" do
      balance = %Balance{
        available: Decimal.new("950"),
        frozen: Decimal.new("50"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("1000"),
        unrealized_pnl: Decimal.new("0")
      }
      
      positions = %{}
      
      order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.001"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("50")
      }
      
      {new_balance, new_positions} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:cancel_order, order}
      )
      
      assert Decimal.equal?(new_balance.available, Decimal.new("1000"))  # 950 + 50
      assert Decimal.equal?(new_balance.frozen, Decimal.new("0"))        # 50 - 50
      assert new_positions == positions  # Positions unchanged on cancellation
    end
  end
  
  describe "calculate_action_effect/3 - fill_order" do
    test "fills buy order creating new long position" do
      balance = %Balance{
        available: Decimal.new("950"),
        frozen: Decimal.new("50"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("1000"),
        unrealized_pnl: Decimal.new("0")
      }
      
      positions = %{}
      
      order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.001"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("50")
      }
      
      fill_price = Decimal.new("50000")
      
      {new_balance, new_positions} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:fill_order, order, fill_price}
      )
      
      # Balance should unfreeze and update margin
      assert Decimal.equal?(new_balance.frozen, Decimal.new("0"))      # Unfrozen
      assert Decimal.equal?(new_balance.margin_used, Decimal.new("50")) # New margin
      
      # New position should be created
      position = new_positions["BTCUSDT"]
      assert position.side == "long"
      assert Decimal.equal?(position.amount, Decimal.new("0.001"))
      assert Decimal.equal?(position.entry_price, Decimal.new("50000"))
      assert Decimal.equal?(position.margin_used, Decimal.new("50"))
    end
    
    test "fills sell order reducing long position" do
      balance = %Balance{
        available: Decimal.new("950"),
        frozen: Decimal.new("0"),  # No additional frozen for position-reducing order
        margin_used: Decimal.new("100"),
        total: Decimal.new("1000"),
        unrealized_pnl: Decimal.new("0")
      }
      
      positions = %{
        "BTCUSDT" => %Position{
          market: "BTCUSDT",
          side: "long",
          amount: Decimal.new("0.002"),
          entry_price: Decimal.new("50000"),
          margin_used: Decimal.new("100"),
          unrealized_pnl: Decimal.new("0"),
          leverage: Decimal.new("1"),
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      }
      
      order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.001"),  # Reduces position by half
        price: Decimal.new("51000"),
        frozen_amount: Decimal.new("0") # No frozen amount for position reduction
      }
      
      fill_price = Decimal.new("51000")
      
      {new_balance, new_positions} = ActionCalculator.calculate_action_effect(
        balance,
        positions,
        {:fill_order, order, fill_price}
      )
      
      # Balance should remain same for frozen (was 0), margin should be updated
      assert Decimal.equal?(new_balance.frozen, Decimal.new("0"))
      assert Decimal.equal?(new_balance.margin_used, Decimal.new("50"))  # Reduced margin
      
      # Position should be reduced
      position = new_positions["BTCUSDT"]
      assert position.side == "long"
      assert Decimal.equal?(position.amount, Decimal.new("0.001"))  # 0.002 - 0.001
      assert Decimal.equal?(position.entry_price, Decimal.new("50000"))  # Same entry price
    end
  end
  
  describe "balance conservation property" do
    test "total balance is conserved across all operations" do
      initial_balance = %Balance{
        available: Decimal.new("1000"),
        frozen: Decimal.new("0"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("1000"),
        unrealized_pnl: Decimal.new("0")
      }
      
      positions = %{}
      
      # Calculate initial total
      initial_total = Decimal.add(
        Decimal.add(initial_balance.available, initial_balance.frozen),
        initial_balance.margin_used
      )
      
      # Place order
      order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.001"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("50")
      }
      
      {balance_after_place, positions_after_place} = ActionCalculator.calculate_action_effect(
        initial_balance,
        positions,
        {:place_order, order}
      )
      
      # Total should be conserved
      total_after_place = Decimal.add(
        Decimal.add(balance_after_place.available, balance_after_place.frozen),
        balance_after_place.margin_used
      )
      
      assert Decimal.equal?(initial_total, total_after_place)
      
      # Cancel order
      {balance_after_cancel, _} = ActionCalculator.calculate_action_effect(
        balance_after_place,
        positions_after_place,
        {:cancel_order, order}
      )
      
      # Total should be conserved and back to original
      total_after_cancel = Decimal.add(
        Decimal.add(balance_after_cancel.available, balance_after_cancel.frozen),
        balance_after_cancel.margin_used
      )
      
      assert Decimal.equal?(initial_total, total_after_cancel)
    end
  end
end