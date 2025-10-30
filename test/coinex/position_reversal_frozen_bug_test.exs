defmodule Coinex.PositionReversalFrozenBugTest do
  @moduledoc """
  Test to reproduce the bug where frozen amounts are incorrect after position reversal
  with pending orders that get cancelled and then new same-side orders are placed.

  Scenario:
  1. Start with a SHORT position
  2. Place multiple SELL orders (same side, some get cancelled)
  3. Price moves and some SELL orders fill
  4. Position reverses to LONG via opposite BUY orders
  5. Then place multiple BUY orders (same side as new LONG position)

  Expected: BUY orders should freeze full margin
  Bug: Frozen amount appears to be ~50% of what it should be
  """
  use ExUnit.Case, async: false

  alias Coinex.FuturesExchange

  setup do
    case Process.whereis(FuturesExchange) do
      nil ->
        {:ok, _pid} = FuturesExchange.start_link([])

      _pid ->
        :ok
    end

    FuturesExchange.reset_state()
    :ok
  end

  test "frozen amount calculation after position reversal from SHORT to LONG" do
    # Step 1: Set initial price
    initial_price = Decimal.new("110000.0")
    FuturesExchange.set_current_price(initial_price)

    # Step 2: Create a SHORT position (sell to open)
    {:ok, _order} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.001", "initial_short")

    positions = FuturesExchange.get_positions()
    assert length(positions) == 1
    [position] = positions
    assert position.side == "short"
    assert Decimal.equal?(position.amount, Decimal.new("0.001"))

    balance_after_short = FuturesExchange.get_balance()
    IO.puts("\n=== After creating SHORT position ===")
    IO.puts("Available: $#{Decimal.to_string(balance_after_short.available)}")
    IO.puts("Frozen: $#{Decimal.to_string(balance_after_short.frozen)}")
    IO.puts("Margin: $#{Decimal.to_string(balance_after_short.margin_used)}")
    IO.puts("Position: SHORT #{Decimal.to_string(position.amount)} BTC")

    # Step 3: Place some SELL limit orders (same side as SHORT position)
    # These should freeze full margin since they increase the SHORT position
    # Place them ABOVE current price so they don't auto-fill
    {:ok, sell_order1} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.0002", "115000.0")
    {:ok, sell_order2} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.0003", "116000.0")

    balance_after_sells = FuturesExchange.get_balance()
    IO.puts("\n=== After placing 2 SELL limit orders (same side) ===")
    IO.puts("Available: $#{Decimal.to_string(balance_after_sells.available)}")
    IO.puts("Frozen: $#{Decimal.to_string(balance_after_sells.frozen)}")

    # Step 4: Cancel these SELL orders
    {:ok, _} = FuturesExchange.cancel_order(sell_order1.id)
    {:ok, _} = FuturesExchange.cancel_order(sell_order2.id)

    balance_after_cancel = FuturesExchange.get_balance()
    IO.puts("\n=== After cancelling SELL orders ===")
    IO.puts("Available: $#{Decimal.to_string(balance_after_cancel.available)}")
    IO.puts("Frozen: $#{Decimal.to_string(balance_after_cancel.frozen)}")

    # Step 5: Reverse position to LONG by placing BUY orders that exceed SHORT position
    # First BUY order: 0.0015 BTC (exceeds SHORT of 0.001, creates LONG of 0.0005)
    {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.0015", "reverse_to_long")

    positions_after_reverse = FuturesExchange.get_positions()
    assert length(positions_after_reverse) == 1
    [position_after_reverse] = positions_after_reverse
    assert position_after_reverse.side == "long"
    assert Decimal.equal?(position_after_reverse.amount, Decimal.new("0.0005"))

    balance_after_reverse = FuturesExchange.get_balance()
    IO.puts("\n=== After reversing to LONG position ===")
    IO.puts("Available: $#{Decimal.to_string(balance_after_reverse.available)}")
    IO.puts("Frozen: $#{Decimal.to_string(balance_after_reverse.frozen)}")
    IO.puts("Margin: $#{Decimal.to_string(balance_after_reverse.margin_used)}")
    IO.puts("Position: LONG #{Decimal.to_string(position_after_reverse.amount)} BTC")
    IO.puts("Unrealized PnL: $#{Decimal.to_string(balance_after_reverse.unrealized_pnl)}")

    # Step 6: Now place multiple BUY limit orders (same side as LONG position)
    # These should freeze FULL margin since they increase the LONG position
    price1 = Decimal.new("109770.12")
    price2 = Decimal.new("109729.16")
    price3 = Decimal.new("109889.00")
    price4 = Decimal.new("109995.89")

    amount1 = Decimal.new("0.00020240")
    amount2 = Decimal.new("0.00020213")
    amount3 = Decimal.new("0.00020139")
    amount4 = Decimal.new("0.00020075")

    {:ok, buy_order1} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", Decimal.to_string(amount1), Decimal.to_string(price1))
    {:ok, buy_order2} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", Decimal.to_string(amount2), Decimal.to_string(price2))
    {:ok, buy_order3} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", Decimal.to_string(amount3), Decimal.to_string(price3))
    {:ok, buy_order4} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", Decimal.to_string(amount4), Decimal.to_string(price4))

    balance_final = FuturesExchange.get_balance()

    IO.puts("\n=== After placing 4 BUY limit orders (same side as LONG) ===")
    IO.puts("Order #1: #{Decimal.to_string(amount1)} BTC @ $#{Decimal.to_string(price1)} = frozen: $#{Decimal.to_string(buy_order1.frozen_amount)}")
    IO.puts("Order #2: #{Decimal.to_string(amount2)} BTC @ $#{Decimal.to_string(price2)} = frozen: $#{Decimal.to_string(buy_order2.frozen_amount)}")
    IO.puts("Order #3: #{Decimal.to_string(amount3)} BTC @ $#{Decimal.to_string(price3)} = frozen: $#{Decimal.to_string(buy_order3.frozen_amount)}")
    IO.puts("Order #4: #{Decimal.to_string(amount4)} BTC @ $#{Decimal.to_string(price4)} = frozen: $#{Decimal.to_string(buy_order4.frozen_amount)}")

    IO.puts("\n=== Final Balance ===")
    IO.puts("Available: $#{Decimal.to_string(balance_final.available)}")
    IO.puts("Frozen: $#{Decimal.to_string(balance_final.frozen)}")
    IO.puts("Margin: $#{Decimal.to_string(balance_final.margin_used)}")
    IO.puts("Unrealized PnL: $#{Decimal.to_string(balance_final.unrealized_pnl)}")

    # Calculate expected frozen amounts
    expected_frozen1 = Decimal.mult(amount1, price1)
    expected_frozen2 = Decimal.mult(amount2, price2)
    expected_frozen3 = Decimal.mult(amount3, price3)
    expected_frozen4 = Decimal.mult(amount4, price4)

    total_expected_frozen =
      expected_frozen1
      |> Decimal.add(expected_frozen2)
      |> Decimal.add(expected_frozen3)
      |> Decimal.add(expected_frozen4)

    IO.puts("\n=== Expected vs Actual ===")
    IO.puts("Expected frozen (order 1): $#{Decimal.to_string(expected_frozen1)}")
    IO.puts("Expected frozen (order 2): $#{Decimal.to_string(expected_frozen2)}")
    IO.puts("Expected frozen (order 3): $#{Decimal.to_string(expected_frozen3)}")
    IO.puts("Expected frozen (order 4): $#{Decimal.to_string(expected_frozen4)}")
    IO.puts("Total expected frozen: $#{Decimal.to_string(total_expected_frozen)}")
    IO.puts("Actual frozen: $#{Decimal.to_string(balance_final.frozen)}")

    # Verify each order froze the correct amount
    assert Decimal.equal?(buy_order1.frozen_amount, expected_frozen1),
      "Order 1 frozen amount mismatch"
    assert Decimal.equal?(buy_order2.frozen_amount, expected_frozen2),
      "Order 2 frozen amount mismatch"
    assert Decimal.equal?(buy_order3.frozen_amount, expected_frozen3),
      "Order 3 frozen amount mismatch"
    assert Decimal.equal?(buy_order4.frozen_amount, expected_frozen4),
      "Order 4 frozen amount mismatch"

    # Verify total frozen matches sum of individual frozen amounts
    assert Decimal.equal?(balance_final.frozen, total_expected_frozen),
      "Total frozen amount should equal sum of all individual frozen amounts"

    # Verify balance integrity
    # Total should equal: available + frozen + unrealized_pnl
    expected_total =
      balance_final.available
      |> Decimal.add(balance_final.frozen)
      |> Decimal.add(balance_final.unrealized_pnl)

    assert Decimal.equal?(balance_final.total, expected_total),
      "Balance integrity check failed"
  end

  test "simpler case: just SHORT to LONG reversal then BUY orders" do
    # Simpler version without the cancelled orders
    initial_price = Decimal.new("110000.0")
    FuturesExchange.set_current_price(initial_price)

    # Create SHORT position
    {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.001")

    # Reverse to LONG
    {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.002")

    positions = FuturesExchange.get_positions()
    assert length(positions) == 1
    [position] = positions
    assert position.side == "long"
    assert Decimal.equal?(position.amount, Decimal.new("0.001"))

    _balance_before_orders = FuturesExchange.get_balance()

    # Place BUY orders (same side as LONG position)
    amount = Decimal.new("0.0002")
    price = Decimal.new("109000.0")

    {:ok, order1} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", Decimal.to_string(amount), Decimal.to_string(price))
    {:ok, order2} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", Decimal.to_string(amount), Decimal.to_string(price))

    # Each order should freeze: 0.0002 * 109000 = 21.8 USDT
    expected_frozen_per_order = Decimal.mult(amount, price)
    total_expected = Decimal.mult(expected_frozen_per_order, Decimal.new("2"))

    IO.puts("\n=== Simpler test ===")
    IO.puts("Expected frozen per order: $#{Decimal.to_string(expected_frozen_per_order)}")
    IO.puts("Order 1 actual frozen: $#{Decimal.to_string(order1.frozen_amount)}")
    IO.puts("Order 2 actual frozen: $#{Decimal.to_string(order2.frozen_amount)}")

    balance_after_orders = FuturesExchange.get_balance()
    IO.puts("Total expected frozen: $#{Decimal.to_string(total_expected)}")
    IO.puts("Total actual frozen: $#{Decimal.to_string(balance_after_orders.frozen)}")

    assert Decimal.equal?(order1.frozen_amount, expected_frozen_per_order)
    assert Decimal.equal?(order2.frozen_amount, expected_frozen_per_order)
    assert Decimal.equal?(balance_after_orders.frozen, total_expected)
  end

  test "price updates don't corrupt frozen balance" do
    # This test verifies the bug fix where update_price was hardcoding total balance to 10000
    initial_price = Decimal.new("110000.0")
    FuturesExchange.set_current_price(initial_price)

    # Create a LONG position
    {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.001")

    # Place multiple BUY orders (same side as LONG)
    {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.0002", "109000.0")
    {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.0002", "109000.0")

    balance_before_price_update = FuturesExchange.get_balance()
    frozen_before = balance_before_price_update.frozen
    total_before = balance_before_price_update.total

    IO.puts("\n=== Before price update ===")
    IO.puts("Frozen: $#{Decimal.to_string(frozen_before)}")
    IO.puts("Total: $#{Decimal.to_string(total_before)}")

    # Update price multiple times (simulating price polling)
    FuturesExchange.set_current_price(Decimal.new("110100.0"))
    FuturesExchange.set_current_price(Decimal.new("110200.0"))
    FuturesExchange.set_current_price(Decimal.new("110050.0"))

    balance_after_price_updates = FuturesExchange.get_balance()
    frozen_after = balance_after_price_updates.frozen
    total_after = balance_after_price_updates.total

    IO.puts("\n=== After price updates ===")
    IO.puts("Frozen: $#{Decimal.to_string(frozen_after)}")
    IO.puts("Total: $#{Decimal.to_string(total_after)}")

    # Frozen amount should NOT change due to price updates
    assert Decimal.equal?(frozen_after, frozen_before),
      "Frozen balance should not be affected by price updates"

    # Total should only change by the change in unrealized PnL
    pnl_change = Decimal.sub(balance_after_price_updates.unrealized_pnl, balance_before_price_update.unrealized_pnl)
    expected_total_after = Decimal.add(total_before, pnl_change)

    assert Decimal.equal?(total_after, expected_total_after),
      "Total balance should only change by unrealized PnL changes"

    # Verify the balance equation still holds
    calculated_total =
      balance_after_price_updates.available
      |> Decimal.add(balance_after_price_updates.frozen)
      |> Decimal.add(balance_after_price_updates.unrealized_pnl)

    assert Decimal.equal?(balance_after_price_updates.total, calculated_total),
      "Total should equal available + frozen + unrealized_pnl"
  end

  test "multiple opposing orders that collectively exceed position should freeze excess" do
    # Bug: Each opposing order is calculated independently against the position
    # without considering cumulative effect of pending opposing orders
    initial_price = Decimal.new("110000.0")
    FuturesExchange.set_current_price(initial_price)

    # Create LONG position
    {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.001")

    positions = FuturesExchange.get_positions()
    [position] = positions
    assert position.side == "long"
    assert Decimal.equal?(position.amount, Decimal.new("0.001"))

    balance_after_position = FuturesExchange.get_balance()
    IO.puts("\n=== After creating LONG position (0.001 BTC) ===")
    IO.puts("Available: $#{Decimal.to_string(balance_after_position.available)}")
    IO.puts("Frozen: $#{Decimal.to_string(balance_after_position.frozen)}")
    IO.puts("Margin: $#{Decimal.to_string(balance_after_position.margin_used)}")

    # Place multiple SELL orders (opposing side) that individually don't exceed position
    # but collectively do exceed it
    price = Decimal.new("111000.0")

    {:ok, order1} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.0003", Decimal.to_string(price))
    IO.puts("\n=== After SELL order #1 (0.0003 BTC) ===")
    IO.puts("Order frozen: $#{Decimal.to_string(order1.frozen_amount)}")

    {:ok, order2} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.0003", Decimal.to_string(price))
    IO.puts("\n=== After SELL order #2 (0.0003 BTC) ===")
    IO.puts("Order frozen: $#{Decimal.to_string(order2.frozen_amount)}")

    {:ok, order3} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.0005", Decimal.to_string(price))
    IO.puts("\n=== After SELL order #3 (0.0005 BTC) ===")
    IO.puts("Order frozen: $#{Decimal.to_string(order3.frozen_amount)}")

    balance_final = FuturesExchange.get_balance()
    IO.puts("\n=== Final balance ===")
    IO.puts("Available: $#{Decimal.to_string(balance_final.available)}")
    IO.puts("Frozen: $#{Decimal.to_string(balance_final.frozen)}")

    # Calculate cumulative order amounts
    total_sell_orders = Decimal.new("0.0003")
      |> Decimal.add(Decimal.new("0.0003"))
      |> Decimal.add(Decimal.new("0.0005"))

    IO.puts("\n=== Analysis ===")
    IO.puts("Position: LONG #{Decimal.to_string(position.amount)} BTC")
    IO.puts("Total SELL orders: #{Decimal.to_string(total_sell_orders)} BTC")
    IO.puts("Excess over position: #{Decimal.to_string(Decimal.sub(total_sell_orders, position.amount))} BTC")

    # The cumulative SELL orders (0.0011) exceed the LONG position (0.001)
    # Expected: The excess (0.0001 BTC) should require frozen margin = 0.0001 * 111000 = 11.1 USDT
    excess_amount = Decimal.sub(total_sell_orders, position.amount)
    expected_frozen = Decimal.mult(excess_amount, price)

    IO.puts("\nExpected frozen for excess: $#{Decimal.to_string(expected_frozen)}")
    IO.puts("Actual frozen: $#{Decimal.to_string(balance_final.frozen)}")

    assert Decimal.equal?(balance_final.frozen, expected_frozen),
      "Frozen amount should account for cumulative opposing orders exceeding position"
  end
end
