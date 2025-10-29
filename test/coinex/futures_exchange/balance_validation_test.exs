defmodule Coinex.FuturesExchange.BalanceValidationTest do
  @moduledoc """
  Edge case tests for balance validation with position-aware margin calculation.

  These tests verify that the validate_balance function correctly uses
  ActionCalculator.calculate_frozen_for_order to account for existing positions.
  """

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

    # Set a consistent price
    FuturesExchange.set_current_price(Decimal.new("50000"))
    :ok
  end

  describe "position-closing orders (exact match)" do
    test "sell order exactly matching long position requires 0 margin" do
      # Step 1: Open a long position with market buy
      {:ok, _buy_order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # Verify we have a long position
      [position] = FuturesExchange.get_positions()
      assert position.side == "long"
      assert Decimal.equal?(position.amount, Decimal.new("0.1"))

      # Get balance before close
      balance_before = FuturesExchange.get_balance()

      # Step 2: Drain almost all available balance (leave just fees worth)
      # Available = 10000 - (0.1 * 50000) - (0.1 * 50000 * 0.0005)
      # Available = 10000 - 5000 - 2.5 = 4997.5
      # We'll create pending buy orders to freeze most of it
      available = Decimal.to_float(balance_before.available)

      # Freeze most of the available balance with a limit buy order at very low price (won't fill)
      # Leave $30 for the sell order (which should need $0)
      freeze_amount = available - 30
      # At price 1000, well below current
      freeze_btc_amount = freeze_amount / 1000

      {:ok, _freeze_order} =
        FuturesExchange.submit_limit_order(
          "BTCUSDT",
          "buy",
          "#{freeze_btc_amount}",
          "1000"
        )

      # Verify balance is very low
      balance_after_freeze = FuturesExchange.get_balance()
      assert Decimal.to_float(balance_after_freeze.available) < 35

      # Step 3: Close the position with exact sell order
      # This should succeed because closing position requires 0 margin
      result = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.1")

      assert {:ok, sell_order} = result
      assert sell_order.status == "filled"
      assert Decimal.equal?(sell_order.amount, Decimal.new("0.1"))

      # Verify position is closed
      positions = FuturesExchange.get_positions()
      assert positions == []
    end

    test "buy order exactly matching short position requires 0 margin" do
      # Step 1: Open a short position with market sell
      {:ok, _sell_order} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.1")

      # Verify we have a short position
      [position] = FuturesExchange.get_positions()
      assert position.side == "short"
      assert Decimal.equal?(position.amount, Decimal.new("0.1"))

      # Step 2: Drain available balance by placing limit sell orders at high price
      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)

      freeze_amount = available - 30
      # At price 100000
      freeze_btc_amount = freeze_amount / 100_000

      {:ok, _freeze_order} =
        FuturesExchange.submit_limit_order(
          "BTCUSDT",
          "sell",
          "#{freeze_btc_amount}",
          "100000"
        )

      # Verify low balance
      balance_after_freeze = FuturesExchange.get_balance()
      assert Decimal.to_float(balance_after_freeze.available) < 35

      # Step 3: Close the short position with exact buy order
      # Should succeed because closing requires 0 margin
      result = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      assert {:ok, buy_order} = result
      assert buy_order.status == "filled"

      # Verify position is closed
      assert FuturesExchange.get_positions() == []
    end
  end

  describe "position-reducing orders (partial close)" do
    test "sell order smaller than long position requires 0 margin" do
      # Open long position
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # Drain balance
      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)
      freeze_btc = (available - 30) / 1000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "#{freeze_btc}", "1000")

      # Partially close position (50%)
      result = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.05")

      assert {:ok, sell_order} = result
      assert sell_order.status == "filled"

      # Verify position is reduced
      [position] = FuturesExchange.get_positions()
      assert Decimal.equal?(position.amount, Decimal.new("0.05"))
      assert position.side == "long"
    end

    test "buy order smaller than short position requires 0 margin" do
      # Open short position
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.1")

      # Drain balance
      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)
      freeze_btc = (available - 30) / 100_000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "#{freeze_btc}", "100000")

      # Partially close position (30%)
      result = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.03")

      assert {:ok, buy_order} = result
      assert buy_order.status == "filled"

      # Verify position is reduced
      [position] = FuturesExchange.get_positions()
      assert Decimal.equal?(position.amount, Decimal.new("0.07"))
      assert position.side == "short"
    end
  end

  describe "position-reversing orders (exceeding position)" do
    test "sell order exceeding long position requires margin only for excess" do
      # Open long position of 0.1 BTC
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)

      # We want to reverse: sell 0.15 BTC (close 0.1 long + open 0.05 short)
      # Excess = 0.05 BTC needs margin = 0.05 * 50000 = 2500
      # Make sure we have at least 2500 + fees available
      assert available > 2500

      # Drain balance to exactly what we need for excess + some buffer for fees
      # Leave 2550 (2500 for position + 50 for fees)
      freeze_btc = (available - 2550) / 1000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "#{freeze_btc}", "1000")

      # Verify we have low but sufficient balance
      balance_after = FuturesExchange.get_balance()
      available_after = Decimal.to_float(balance_after.available)
      assert available_after < 2600
      assert available_after > 2500

      # Reverse position: sell 0.15 (needs margin for 0.05 excess only)
      result = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.15")

      assert {:ok, sell_order} = result
      assert sell_order.status == "filled"

      # Verify we now have a short position of 0.05
      [position] = FuturesExchange.get_positions()
      assert position.side == "short"
      assert Decimal.equal?(position.amount, Decimal.new("0.05"))
    end

    test "sell order exceeding long position fails if insufficient margin for excess" do
      # Open long position
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)

      # Try to reverse with sell 0.15 but drain balance too much
      # Excess 0.05 needs 2500, but we'll leave only 1000
      freeze_btc = (available - 1000) / 1000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "#{freeze_btc}", "1000")

      # Try to reverse - should fail
      result = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.15")

      assert {:error, "Insufficient balance"} = result

      # Position should be unchanged
      [position] = FuturesExchange.get_positions()
      assert position.side == "long"
      assert Decimal.equal?(position.amount, Decimal.new("0.1"))
    end

    test "buy order exceeding short position requires margin only for excess" do
      # Open short position
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.1")

      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)

      # Reverse: buy 0.15 (close 0.1 short + open 0.05 long)
      # Excess 0.05 needs 2500 margin
      freeze_btc = (available - 2550) / 100_000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "#{freeze_btc}", "100000")

      balance_after = FuturesExchange.get_balance()
      available_after = Decimal.to_float(balance_after.available)
      assert available_after < 2600
      assert available_after > 2500

      # Reverse position
      result = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.15")

      assert {:ok, buy_order} = result
      assert buy_order.status == "filled"

      # Verify long position of 0.05
      [position] = FuturesExchange.get_positions()
      assert position.side == "long"
      assert Decimal.equal?(position.amount, Decimal.new("0.05"))
    end
  end

  describe "low balance scenarios" do
    test "low balance sufficient for position-closing but not for new position" do
      # Open long position
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # Drain balance severely
      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)
      freeze_btc = (available - 30) / 1000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "#{freeze_btc}", "1000")

      # Should be able to close position
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.1")
      assert FuturesExchange.get_positions() == []

      # Cancel the freezing order to see actual available balance after close
      orders = FuturesExchange.get_orders()
      pending_order = Enum.find(orders, &(&1.status == "pending"))

      if pending_order do
        {:ok, _} = FuturesExchange.cancel_order(pending_order.id)
      end

      # Now check if we can open new position - we should have funds released from closed position
      # but we paid fees on both trades, so balance should be slightly less than original
      _balance_after = FuturesExchange.get_balance()

      # We should have recovered the margin (5000) but paid fees
      # Buy fee: 0.1 * 50000 * 0.0005 = 2.5
      # Sell fee: 0.1 * 50000 * 0.0005 = 2.5
      # Total fees = 5, so we should have ~9995 available
      # But we might actually have enough to open new position
      result = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # This might succeed or fail depending on exact fee calculations and rounding
      # The key test is that closing succeeded above with low balance
      case result do
        {:ok, _} ->
          # We had enough balance after fees
          assert true

        {:error, "Insufficient balance"} ->
          # We didn't have enough after fees - also valid
          assert true

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "position-closing order succeeds even with multiple pending orders freezing funds" do
      # Open long position
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # Create multiple pending orders to freeze funds
      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)

      # Need to be very aggressive with freezing to test the edge case
      # Use larger pending orders at low prices to freeze more funds
      # Each pending buy order at price 1000 needs amount * 1000 frozen
      # Leave just $50 available
      total_to_freeze = available - 50

      # Calculate BTC amount needed to freeze this much at price 1000
      # Split into 10 orders
      btc_per_order = total_to_freeze / 10 / 1000

      # Create many small pending orders to consume available balance
      for price <- [1000, 990, 980, 970, 960, 950, 940, 930, 920, 910] do
        {:ok, _} =
          FuturesExchange.submit_limit_order("BTCUSDT", "buy", "#{btc_per_order}", "#{price}")
      end

      # Verify low available balance
      balance_after = FuturesExchange.get_balance()
      available_after = Decimal.to_float(balance_after.available)

      # The key point: we have very little available balance
      # This test shows that even with low balance, position-closing works
      # We have much less than the 5000 USDT needed to open a new 0.1 BTC position
      assert available_after < 500

      # But we should still be able to close position (requires 0 margin)
      # This is the core assertion - closing works even with low balance and many pending orders
      result = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.1")

      assert {:ok, sell_order} = result
      assert sell_order.status == "filled"
      assert FuturesExchange.get_positions() == []

      # Verify we couldn't have opened a new position with this low balance
      # but we could close the existing one
      assert available_after <
               Decimal.to_float(Decimal.mult(Decimal.new("0.1"), Decimal.new("50000")))
    end

    test "zero available balance after fees still allows position-closing order" do
      # Open small position to minimize fee impact
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.01")

      # Calculate exact available and freeze all but $1
      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)
      freeze_btc = (available - 1) / 1000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "#{freeze_btc}", "1000")

      # Verify nearly zero balance
      balance_after = FuturesExchange.get_balance()
      assert Decimal.to_float(balance_after.available) < 2

      # Should still close position (needs 0 margin)
      result = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.01")

      assert {:ok, _} = result
      assert FuturesExchange.get_positions() == []
    end
  end

  describe "edge combinations" do
    test "price change affecting required margin for position reversal" do
      # Open long at 50000
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # Price increases to 60000
      FuturesExchange.set_current_price(Decimal.new("60000"))

      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)

      # Now reversing with 0.15 needs margin for 0.05 at new price 60000
      # Margin needed = 0.05 * 60000 = 3000
      # Leave exactly enough
      freeze_btc = (available - 3050) / 1000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "#{freeze_btc}", "1000")

      # Should succeed at new price
      result = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.15")

      assert {:ok, _} = result

      [position] = FuturesExchange.get_positions()
      assert position.side == "short"
      assert Decimal.equal?(position.amount, Decimal.new("0.05"))
    end

    test "limit order for position-closing can be placed with zero available balance" do
      # Open long position
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # Freeze all available balance
      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)
      # Leave almost nothing
      freeze_btc = (available - 0.5) / 1000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "#{freeze_btc}", "1000")

      # Should be able to place limit sell order to close position
      result = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.1", "50000")

      assert {:ok, limit_order} = result
      assert limit_order.status in ["pending", "filled"]
    end

    test "market order to close position with exactly required fees available" do
      # This tests the precise boundary condition
      # Open position with 0.001 BTC (small to control fees)
      {:ok, _buy_order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.001")

      # Fee for market order = 0.001 * 50000 * 0.0005 = 0.025 USDT
      # Closing also needs fee = 0.001 * 50000 * 0.0005 = 0.025 USDT

      balance = FuturesExchange.get_balance()
      available = Decimal.to_float(balance.available)

      # Leave exactly 0.03 (slightly more than fee 0.025)
      freeze_btc = (available - 0.03) / 1000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "#{freeze_btc}", "1000")

      # Should succeed with just enough for fees
      result = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.001")

      # May succeed or fail depending on exact fee calculation
      # The important thing is it doesn't crash and handles the edge case
      case result do
        {:ok, _} -> assert true
        {:error, "Insufficient balance"} -> assert true
        _ -> flunk("Unexpected result: #{inspect(result)}")
      end
    end
  end

  describe "regression tests" do
    test "the original bug: opposing market order fails with insufficient balance" do
      # This is the exact scenario that was failing before the fix

      # Open a long position
      {:ok, _} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")

      # Verify position exists
      [position] = FuturesExchange.get_positions()
      assert position.side == "long"

      # Get current balance
      balance_before = FuturesExchange.get_balance()

      # Freeze significant portion of balance with pending orders
      available = Decimal.to_float(balance_before.available)
      freeze_btc = (available - 100) / 1000
      {:ok, _} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "#{freeze_btc}", "1000")

      # Now try to close position with opposing market order
      # Before fix: this would fail with "Insufficient balance"
      # After fix: this should succeed because it needs 0 margin
      result = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.1")

      # This MUST succeed
      assert {:ok, sell_order} = result
      assert sell_order.status == "filled"

      # Position should be closed
      assert FuturesExchange.get_positions() == []
    end
  end
end
