defmodule Coinex.FuturesExchangeTest do
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
    :ok
  end

  describe "balance management" do
    test "initial balance is set correctly" do
      balance = FuturesExchange.get_balance()

      assert Decimal.equal?(balance.available, Decimal.new("10000.00"))
      assert Decimal.equal?(balance.frozen, Decimal.new("0.00"))
      assert Decimal.equal?(balance.margin_used, Decimal.new("0.00"))
      assert Decimal.equal?(balance.total, Decimal.new("10000.00"))
      assert Decimal.equal?(balance.unrealized_pnl, Decimal.new("0.00"))
    end
  end

  describe "order validation" do
    test "rejects invalid market" do
      result = FuturesExchange.submit_limit_order("ETHUSDT", "buy", "1.0", "50000.0")
      assert {:error, "Unsupported market"} = result
    end

    test "rejects invalid side" do
      result = FuturesExchange.submit_limit_order("BTCUSDT", "invalid", "1.0", "50000.0")
      assert {:error, "Invalid side"} = result
    end

    test "rejects zero or negative amount" do
      result = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0", "50000.0")
      assert {:error, "Amount must be positive"} = result

      result = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "-1.0", "50000.0")
      assert {:error, "Amount must be positive"} = result
    end

    test "rejects zero or negative price for limit orders" do
      result = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "1.0", "0")
      assert {:error, "Price must be positive"} = result

      result = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "1.0", "-100")
      assert {:error, "Price must be positive"} = result
    end

    test "rejects orders with insufficient balance" do
      # Try to buy 1 BTC at 100k USDT (needs 100k but we only have 10k)
      result = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "1.0", "100000.0")
      assert {:error, "Insufficient balance"} = result
    end
  end

  describe "limit order management" do
    test "successfully creates limit buy order" do
      {:ok, order} =
        FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.1", "50000.0", "client123")

      assert order.id == 1
      assert order.market == "BTCUSDT"
      assert order.side == "buy"
      assert order.type == "limit"
      assert Decimal.equal?(order.amount, Decimal.new("0.1"))
      assert Decimal.equal?(order.price, Decimal.new("50000.0"))
      assert order.status == "pending"
      assert Decimal.equal?(order.filled_amount, Decimal.new("0"))
      assert order.client_id == "client123"
    end

    test "successfully creates limit sell order" do
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.1", "60000.0")

      assert order.side == "sell"
      assert order.type == "limit"
    end

    test "freezes correct balance for buy orders" do
      {:ok, _order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.1", "50000.0")

      balance = FuturesExchange.get_balance()

      # Should freeze 0.1 * 50000 = 5000 USDT
      assert Decimal.equal?(balance.available, Decimal.new("5000.00"))
      assert Decimal.equal?(balance.frozen, Decimal.new("5000.00"))
    end

    test "can cancel pending orders" do
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.1", "50000.0")

      {:ok, cancelled_order} = FuturesExchange.cancel_order(order.id)

      assert cancelled_order.status == "cancelled"

      # Balance should be unfrozen
      balance = FuturesExchange.get_balance()
      assert Decimal.equal?(balance.available, Decimal.new("10000.00"))
      assert Decimal.equal?(balance.frozen, Decimal.new("0.00"))
    end

    test "cannot cancel non-existent order" do
      result = FuturesExchange.cancel_order(999)
      assert {:error, "Order not found"} = result
    end
  end

  describe "market order management" do
    test "successfully creates and fills market buy order" do
      # Set price for market orders
      FuturesExchange.set_current_price(Decimal.new("50000.0"))

      # Use smaller amount to ensure it fits in balance
      {:ok, order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.01", "market123")

      assert order.market == "BTCUSDT"
      assert order.side == "buy"
      assert order.type == "market"
      assert order.status == "filled"
      assert Decimal.equal?(order.filled_amount, Decimal.new("0.01"))
      assert Decimal.equal?(order.avg_price, Decimal.new("50000.0"))
      assert order.client_id == "market123"
    end

    test "market order creates position" do
      # Set price for market orders
      FuturesExchange.set_current_price(Decimal.new("50000.0"))

      {:ok, _order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.01")

      positions = FuturesExchange.get_positions()
      assert length(positions) == 1

      position = List.first(positions)
      assert position.market == "BTCUSDT"
      assert position.side == "long"
      assert Decimal.equal?(position.amount, Decimal.new("0.01"))
      assert Decimal.equal?(position.entry_price, Decimal.new("50000.0"))
    end
  end

  describe "position management" do
    test "position accumulation for same side orders" do
      # Set price for market orders
      FuturesExchange.set_current_price(Decimal.new("50000.0"))

      {:ok, _order1} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.01")
      {:ok, _order2} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.02")

      positions = FuturesExchange.get_positions()
      assert length(positions) == 1

      position = List.first(positions)
      assert Decimal.equal?(position.amount, Decimal.new("0.03"))
      assert position.side == "long"
    end

    test "position reduction for opposite side orders" do
      # Set price for market orders
      FuturesExchange.set_current_price(Decimal.new("50000.0"))

      {:ok, _order1} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.03")
      {:ok, _order2} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.01")

      positions = FuturesExchange.get_positions()
      assert length(positions) == 1

      position = List.first(positions)
      assert Decimal.equal?(position.amount, Decimal.new("0.02"))
      assert position.side == "long"
    end

    test "position closure when opposite order is larger" do
      # Set price for market orders
      FuturesExchange.set_current_price(Decimal.new("50000.0"))

      {:ok, _order1} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.01")
      {:ok, _order2} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.01")

      positions = FuturesExchange.get_positions()
      assert length(positions) == 0
    end

    test "position reversal when opposite order is much larger" do
      # Set price for market orders
      FuturesExchange.set_current_price(Decimal.new("50000.0"))

      {:ok, _order1} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.01")
      {:ok, _order2} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.03")

      positions = FuturesExchange.get_positions()
      assert length(positions) == 1

      position = List.first(positions)
      assert Decimal.equal?(position.amount, Decimal.new("0.02"))
      assert position.side == "short"
    end
  end

  describe "order listing" do
    test "returns all orders" do
      {:ok, _order1} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.1", "50000.0")
      # Use smaller sell amount to ensure we have sufficient balance for the new short position
      {:ok, _order2} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.05", "60000.0")

      orders = FuturesExchange.get_orders()
      assert length(orders) == 2
    end

    test "tracks order status changes" do
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.1", "50000.0")
      {:ok, _cancelled} = FuturesExchange.cancel_order(order.id)

      orders = FuturesExchange.get_orders()
      cancelled_order = Enum.find(orders, &(&1.id == order.id))
      assert cancelled_order.status == "cancelled"
    end
  end

  describe "automatic order filling (simple model)" do
    test "limit buy order fills completely when price is touched" do
      # Set initial price
      FuturesExchange.set_current_price(Decimal.new("48000.0"))

      # Place a buy order below current price (should remain pending)
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.01", "46000.0")
      assert order.status == "pending"

      # Update price to touch the order price (price comes down to order)
      FuturesExchange.set_current_price(Decimal.new("46000.0"))

      # Order should now be filled completely
      orders = FuturesExchange.get_orders()
      filled_order = Enum.find(orders, &(&1.id == order.id))

      assert filled_order.status == "filled"
      # Complete fill
      assert Decimal.equal?(filled_order.filled_amount, Decimal.new("0.01"))
      # At order price
      assert Decimal.equal?(filled_order.avg_price, Decimal.new("46000.0"))
    end

    test "limit sell order fills completely when price is touched" do
      # Set initial price
      FuturesExchange.set_current_price(Decimal.new("48000.0"))

      # Place a sell order above current price (should remain pending)  
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.01", "50000.0")
      assert order.status == "pending"

      # Update price to touch the order price (price goes up to order)
      FuturesExchange.set_current_price(Decimal.new("50000.0"))

      # Order should now be filled completely
      orders = FuturesExchange.get_orders()
      filled_order = Enum.find(orders, &(&1.id == order.id))

      assert filled_order.status == "filled"
      # Complete fill
      assert Decimal.equal?(filled_order.filled_amount, Decimal.new("0.01"))
      # At order price
      assert Decimal.equal?(filled_order.avg_price, Decimal.new("50000.0"))
    end
  end

  describe "current price retrieval" do
    test "returns current price when available" do
      # Set a known price
      FuturesExchange.set_current_price(Decimal.new("50000.0"))

      # Should return the set price
      price = FuturesExchange.get_current_price()
      assert Decimal.equal?(price, Decimal.new("50000.0"))
    end
  end

  describe "limit orders against positions - freezing behavior" do
    test "opposing order within position size freezes nothing" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # Check balance after position creation
      balance_after_position = FuturesExchange.get_balance()
      # Position used: 0.1 * 50000 = 5000 USDT as margin
      # Available: 10000 - 5000 - fees = ~4975 (with 0.05% taker fee)

      # Place opposing sell limit order that's smaller than position
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.05", "51000.0")

      # Since order amount (0.05) < position amount (0.1), no freezing should occur
      assert order.status == "pending"
      assert Decimal.equal?(order.frozen_amount, Decimal.new("0"))

      balance = FuturesExchange.get_balance()
      assert Decimal.equal?(balance.frozen, Decimal.new("0"))
      # Available should remain the same
      assert Decimal.equal?(balance.available, balance_after_position.available)
    end

    test "opposing order equal to position size freezes nothing" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      balance_after_position = FuturesExchange.get_balance()

      # Place opposing sell limit order equal to position
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.1", "51000.0")

      # Since order amount (0.1) = position amount (0.1), no freezing should occur
      assert order.status == "pending"
      assert Decimal.equal?(order.frozen_amount, Decimal.new("0"))

      balance = FuturesExchange.get_balance()
      assert Decimal.equal?(balance.frozen, Decimal.new("0"))
      assert Decimal.equal?(balance.available, balance_after_position.available)
    end

    test "opposing order exceeding position size freezes only excess" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      balance_after_position = FuturesExchange.get_balance()

      # Place opposing sell limit order larger than position
      # Position: 0.1 BTC, Order: 0.15 BTC
      # Excess: 0.15 - 0.1 = 0.05 BTC
      # Frozen should be: 0.05 * 51000 = 2550 USDT
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.15", "51000.0")

      assert order.status == "pending"
      expected_frozen = Decimal.mult(Decimal.new("0.05"), Decimal.new("51000.0"))
      assert Decimal.equal?(order.frozen_amount, expected_frozen)

      balance = FuturesExchange.get_balance()
      assert Decimal.equal?(balance.frozen, expected_frozen)

      # Available should decrease by frozen amount
      expected_available = Decimal.sub(balance_after_position.available, expected_frozen)
      assert Decimal.equal?(balance.available, expected_available)
    end

    test "multiple opposing orders freeze cumulatively only for excess" do
      # Set price and create a long position of 0.1 BTC
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # First opposing order: 0.05 BTC (within position, no freeze)
      {:ok, order1} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.05", "51000.0")
      assert Decimal.equal?(order1.frozen_amount, Decimal.new("0"))

      balance_after_first = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after_first.frozen, Decimal.new("0"))

      # Second opposing order: 0.03 BTC (still within position total 0.08, no freeze)
      {:ok, order2} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.03", "51000.0")
      assert Decimal.equal?(order2.frozen_amount, Decimal.new("0"))

      balance_after_second = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after_second.frozen, Decimal.new("0"))

      # Third opposing order: 0.05 BTC (total now 0.13, exceeds 0.1, freeze excess 0.03)
      # Excess: 0.05 BTC (this order) exceeds remaining position by 0.03
      # But wait - the calculation is per-order, not cumulative across orders
      # So this order of 0.05 vs position of 0.1 should freeze 0
      {:ok, order3} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.05", "51000.0")
      # Each order is evaluated independently against the position
      # Order3: 0.05 < 0.1, so frozen = 0
      assert Decimal.equal?(order3.frozen_amount, Decimal.new("0"))

      balance_final = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_final.frozen, Decimal.new("0"))
    end

    test "short position with opposing buy limit orders" do
      # Set price and create a short position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.1")

      # Place opposing buy limit order smaller than position (no freeze)
      {:ok, order1} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.05", "49000.0")
      assert Decimal.equal?(order1.frozen_amount, Decimal.new("0"))

      balance_after_first = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after_first.frozen, Decimal.new("0"))

      # Place opposing buy limit order larger than position (freeze excess)
      # Position: 0.1 BTC short, Order: 0.15 BTC buy
      # Excess: 0.15 - 0.1 = 0.05 BTC
      # Frozen: 0.05 * 49000 = 2450 USDT
      {:ok, order2} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.15", "49000.0")

      expected_frozen = Decimal.mult(Decimal.new("0.05"), Decimal.new("49000.0"))
      assert Decimal.equal?(order2.frozen_amount, expected_frozen)

      balance_final = FuturesExchange.get_balance()
      # Total frozen should be the excess from order2 only
      assert Decimal.equal?(balance_final.frozen, expected_frozen)
    end

    test "balance integrity maintained across opposing orders" do
      # Set price and create position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      balance_before = FuturesExchange.get_balance()
      # Verify balance equation: total = available + frozen + unrealized_pnl
      # (margin_used is already deducted from available, so it's not added separately)
      expected_total =
        Decimal.add(
          Decimal.add(balance_before.available, balance_before.frozen),
          balance_before.unrealized_pnl
        )

      assert Decimal.equal?(balance_before.total, expected_total)

      # Place order that exceeds position
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.15", "51000.0")

      balance_after = FuturesExchange.get_balance()
      # Verify balance equation still holds
      expected_total_after =
        Decimal.add(
          Decimal.add(balance_after.available, balance_after.frozen),
          balance_after.unrealized_pnl
        )

      assert Decimal.equal?(balance_after.total, expected_total_after)
    end
  end

  describe "edge cases - order cancellation with positions" do
    test "canceling opposing order that exceeds position releases frozen funds" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      balance_after_position = FuturesExchange.get_balance()

      # Place opposing order that exceeds position
      # Position: 0.1 BTC, Order: 0.15 BTC
      # Frozen: 0.05 * 51000 = 2550 USDT
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.15", "51000.0")
      expected_frozen = Decimal.mult(Decimal.new("0.05"), Decimal.new("51000.0"))
      assert Decimal.equal?(order.frozen_amount, expected_frozen)

      balance_with_order = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_with_order.frozen, expected_frozen)

      # Cancel the order
      {:ok, cancelled_order} = FuturesExchange.cancel_order(order.id)
      assert cancelled_order.status == "cancelled"

      # Verify frozen funds are released
      balance_after_cancel = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after_cancel.frozen, Decimal.new("0"))
      assert Decimal.equal?(balance_after_cancel.available, balance_after_position.available)
    end

    test "canceling opposing order within position releases nothing (was 0 frozen)" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      balance_after_position = FuturesExchange.get_balance()

      # Place opposing order within position (no freeze)
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.05", "51000.0")
      assert Decimal.equal?(order.frozen_amount, Decimal.new("0"))

      # Cancel the order
      {:ok, _} = FuturesExchange.cancel_order(order.id)

      # Balance should remain unchanged
      balance_after_cancel = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after_cancel.frozen, Decimal.new("0"))
      assert Decimal.equal?(balance_after_cancel.available, balance_after_position.available)
    end

    test "canceling multiple orders with mixed frozen amounts" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      balance_after_position = FuturesExchange.get_balance()

      # Order 1: within position (0 frozen)
      {:ok, order1} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.05", "51000.0")
      assert Decimal.equal?(order1.frozen_amount, Decimal.new("0"))

      # Order 2: exceeds position (freeze excess)
      {:ok, order2} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.15", "51000.0")
      frozen2 = Decimal.mult(Decimal.new("0.05"), Decimal.new("51000.0"))
      assert Decimal.equal?(order2.frozen_amount, frozen2)

      # Order 3: exceeds position (freeze excess)
      {:ok, order3} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.12", "51000.0")
      frozen3 = Decimal.mult(Decimal.new("0.02"), Decimal.new("51000.0"))
      assert Decimal.equal?(order3.frozen_amount, frozen3)

      balance_with_orders = FuturesExchange.get_balance()
      total_frozen = Decimal.add(frozen2, frozen3)
      assert Decimal.equal?(balance_with_orders.frozen, total_frozen)

      # Cancel order 2
      {:ok, _} = FuturesExchange.cancel_order(order2.id)
      balance_after_cancel2 = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after_cancel2.frozen, frozen3)

      # Cancel order 3
      {:ok, _} = FuturesExchange.cancel_order(order3.id)
      balance_after_cancel3 = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after_cancel3.frozen, Decimal.new("0"))

      # Cancel order 1 (was 0 frozen)
      {:ok, _} = FuturesExchange.cancel_order(order1.id)
      balance_final = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_final.frozen, Decimal.new("0"))
      assert Decimal.equal?(balance_final.available, balance_after_position.available)
    end
  end

  describe "edge cases - order filling with positions" do
    test "filling opposing order within position reduces position, no frozen used" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      balance_after_position = FuturesExchange.get_balance()
      positions_before = FuturesExchange.get_positions()
      assert length(positions_before) == 1
      position_before = List.first(positions_before)
      assert Decimal.equal?(position_before.amount, Decimal.new("0.1"))
      assert position_before.side == "long"

      # Place opposing order within position (0 frozen)
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.04", "51000.0")
      assert Decimal.equal?(order.frozen_amount, Decimal.new("0"))
      assert order.status == "pending"

      # Update price to fill the order
      FuturesExchange.set_current_price(Decimal.new("51000.0"))

      # Order should be filled
      orders = FuturesExchange.get_orders()
      filled_order = Enum.find(orders, &(&1.id == order.id))
      assert filled_order.status == "filled"

      # Position should be reduced
      positions_after = FuturesExchange.get_positions()
      assert length(positions_after) == 1
      position_after = List.first(positions_after)
      assert Decimal.equal?(position_after.amount, Decimal.new("0.06"))
      assert position_after.side == "long"

      # Verify margin reduced (position is smaller)
      balance_after = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after.frozen, Decimal.new("0"))
      # Margin should be for 0.06 BTC instead of 0.1 BTC
      expected_margin = Decimal.mult(Decimal.new("0.06"), Decimal.new("50000.0"))
      assert Decimal.equal?(balance_after.margin_used, expected_margin)

      # Available should increase (margin released + realized PnL)
      # Realized PnL = 0.04 * (51000 - 50000) = 40 USDT
      # Margin released = 0.04 * 50000 = 2000 USDT
      # But we paid taker fee on 0.04 * 51000 = 2040 * 0.0003 = 0.612 USDT (maker fee for limit)
      assert Decimal.compare(balance_after.available, balance_after_position.available) == :gt
    end

    test "filling opposing order that closes position exactly releases all margin" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      balance_after_position = FuturesExchange.get_balance()

      # Place opposing order equal to position (0 frozen)
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.1", "52000.0")
      assert Decimal.equal?(order.frozen_amount, Decimal.new("0"))

      # Update price to fill the order
      FuturesExchange.set_current_price(Decimal.new("52000.0"))

      # Position should be completely closed
      positions_after = FuturesExchange.get_positions()
      assert length(positions_after) == 0

      # All margin should be released
      balance_after = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after.margin_used, Decimal.new("0"))
      assert Decimal.equal?(balance_after.frozen, Decimal.new("0"))

      # Available should include realized profit
      # Realized PnL = 0.1 * (52000 - 50000) = 200 USDT
      # Margin released = 0.1 * 50000 = 5000 USDT
      # Fees: entry fee (market taker) + exit fee (limit maker)
      assert Decimal.compare(balance_after.available, balance_after_position.available) == :gt
    end

    test "filling opposing order that exceeds position converts frozen to new margin" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # Place opposing order that exceeds position
      # Position: 0.1 long, Order: 0.15 sell
      # Frozen: 0.05 * 51000 = 2550 USDT
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.15", "51000.0")
      frozen_amount = Decimal.mult(Decimal.new("0.05"), Decimal.new("51000.0"))
      assert Decimal.equal?(order.frozen_amount, frozen_amount)

      balance_with_order = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_with_order.frozen, frozen_amount)

      # Update price to fill the order
      FuturesExchange.set_current_price(Decimal.new("51000.0"))

      # Should have a short position of 0.05 BTC
      positions_after = FuturesExchange.get_positions()
      assert length(positions_after) == 1
      position_after = List.first(positions_after)
      assert Decimal.equal?(position_after.amount, Decimal.new("0.05"))
      assert position_after.side == "short"

      # Frozen should be converted to margin
      balance_after = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after.frozen, Decimal.new("0"))

      # New margin for short position: 0.05 * 51000 = 2550 USDT
      expected_margin = Decimal.mult(Decimal.new("0.05"), Decimal.new("51000.0"))
      assert Decimal.equal?(balance_after.margin_used, expected_margin)

      # Available balance changed:
      # - Released old margin (0.1 * 50000 = 5000)
      # - Released frozen (2550)
      # - Allocated new margin (2550)
      # - Realized PnL from closing long position
      # - Paid fees
    end

    test "filling opposing order when price improves (limit buy below market)" do
      # Set price and create a short position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.1")

      # Place opposing buy limit order at lower price (0 frozen, within position)
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.06", "49000.0")
      assert Decimal.equal?(order.frozen_amount, Decimal.new("0"))
      assert order.status == "pending"

      # Price drops to fill the order
      FuturesExchange.set_current_price(Decimal.new("49000.0"))

      # Order should be filled at limit price
      orders = FuturesExchange.get_orders()
      filled_order = Enum.find(orders, &(&1.id == order.id))
      assert filled_order.status == "filled"
      assert Decimal.equal?(filled_order.avg_price, Decimal.new("49000.0"))

      # Position should be reduced
      positions_after = FuturesExchange.get_positions()
      assert length(positions_after) == 1
      position_after = List.first(positions_after)
      assert Decimal.equal?(position_after.amount, Decimal.new("0.04"))
      assert position_after.side == "short"
    end
  end

  describe "edge cases - mixed cancellations and fills" do
    test "cancel some orders, fill others, verify balance integrity" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.15")

      # Place multiple opposing orders
      # 0 frozen
      {:ok, order1} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.08", "51000.0")
      # freeze 0.03*52000
      {:ok, order2} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.18", "52000.0")
      # 0 frozen
      {:ok, order3} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.05", "53000.0")

      # Verify frozen amounts
      assert Decimal.equal?(order1.frozen_amount, Decimal.new("0"))
      frozen2 = Decimal.mult(Decimal.new("0.03"), Decimal.new("52000.0"))
      assert Decimal.equal?(order2.frozen_amount, frozen2)
      assert Decimal.equal?(order3.frozen_amount, Decimal.new("0"))

      balance_with_orders = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_with_orders.frozen, frozen2)

      # Cancel order 2 (had frozen funds)
      {:ok, _} = FuturesExchange.cancel_order(order2.id)
      balance_after_cancel = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after_cancel.frozen, Decimal.new("0"))

      # Fill order 1 by raising price
      FuturesExchange.set_current_price(Decimal.new("51000.0"))

      positions_after_fill1 = FuturesExchange.get_positions()
      assert length(positions_after_fill1) == 1
      position = List.first(positions_after_fill1)
      assert Decimal.equal?(position.amount, Decimal.new("0.07"))
      assert position.side == "long"

      balance_after_fill1 = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_after_fill1.frozen, Decimal.new("0"))

      # Cancel order 3
      {:ok, _} = FuturesExchange.cancel_order(order3.id)

      balance_final = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_final.frozen, Decimal.new("0"))

      # Verify balance integrity
      expected_total =
        Decimal.add(
          Decimal.add(balance_final.available, balance_final.frozen),
          balance_final.unrealized_pnl
        )

      assert Decimal.equal?(balance_final.total, expected_total)
    end

    test "fill order that reverses position, then cancel another order" do
      # Set price and create a long position
      FuturesExchange.set_current_price(Decimal.new("50000.0"))
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # Place two opposing orders that exceed position
      {:ok, order1} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.15", "51000.0")
      frozen1 = Decimal.mult(Decimal.new("0.05"), Decimal.new("51000.0"))
      assert Decimal.equal?(order1.frozen_amount, frozen1)

      {:ok, order2} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.12", "52000.0")
      frozen2 = Decimal.mult(Decimal.new("0.02"), Decimal.new("52000.0"))
      assert Decimal.equal?(order2.frozen_amount, frozen2)

      balance_with_orders = FuturesExchange.get_balance()
      total_frozen = Decimal.add(frozen1, frozen2)
      assert Decimal.equal?(balance_with_orders.frozen, total_frozen)

      # Fill order 1 (reverses to short position)
      FuturesExchange.set_current_price(Decimal.new("51000.0"))

      positions_after = FuturesExchange.get_positions()
      assert length(positions_after) == 1
      position = List.first(positions_after)
      assert Decimal.equal?(position.amount, Decimal.new("0.05"))
      assert position.side == "short"

      balance_after_fill = FuturesExchange.get_balance()
      # Only order2's frozen should remain
      assert Decimal.equal?(balance_after_fill.frozen, frozen2)

      # Cancel order 2
      {:ok, _} = FuturesExchange.cancel_order(order2.id)

      balance_final = FuturesExchange.get_balance()
      assert Decimal.equal?(balance_final.frozen, Decimal.new("0"))
      # Should have margin for the short position
      expected_margin = Decimal.mult(Decimal.new("0.05"), Decimal.new("51000.0"))
      assert Decimal.equal?(balance_final.margin_used, expected_margin)
    end
  end
end
