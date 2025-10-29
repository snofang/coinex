defmodule Coinex.FeeCalculationTest do
  use ExUnit.Case

  alias Coinex.FuturesExchange.{ActionCalculator, Balance, Position, Order}

  describe "CoinEx Fee Calculation Tests" do
    test "market order applies taker fee (0.05%)" do
      balance = %Balance{
        available: Decimal.new("10000"),
        # Already frozen when order was placed
        frozen: Decimal.new("500"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }

      positions = %{}

      # Market buy order for 0.01 BTC at $50,000
      market_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.01"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("500")
      }

      fill_price = Decimal.new("50000")

      {new_balance, new_positions} =
        ActionCalculator.calculate_action_effect(
          balance,
          positions,
          {:fill_order, market_order, fill_price}
        )

      # Order value: 0.01 * 50000 = 500 USDT
      # Taker fee: 500 * 0.0005 = 0.25 USDT
      expected_fee = Decimal.new("0.25")
      # 10000 + 500 (unfreeze) - 0.25 (fee) - 500 (margin)
      expected_available = Decimal.new("9999.75")

      assert Decimal.equal?(new_balance.total_fees_paid, expected_fee)
      assert Decimal.equal?(new_balance.available, expected_available)
      # Unfrozen
      assert Decimal.equal?(new_balance.frozen, Decimal.new("0"))
      # New position margin
      assert Decimal.equal?(new_balance.margin_used, Decimal.new("500"))

      # Position should be created
      position = new_positions["BTCUSDT"]
      assert position != nil
      assert position.side == "long"
      assert Decimal.equal?(position.amount, Decimal.new("0.01"))
    end

    test "limit order applies maker fee (0.03%)" do
      balance = %Balance{
        available: Decimal.new("10000"),
        # Already frozen when order was placed
        frozen: Decimal.new("500"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }

      positions = %{}

      # Limit buy order for 0.01 BTC at $50,000
      limit_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "limit",
        amount: Decimal.new("0.01"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("500")
      }

      fill_price = Decimal.new("50000")

      {new_balance, new_positions} =
        ActionCalculator.calculate_action_effect(
          balance,
          positions,
          {:fill_order, limit_order, fill_price}
        )

      # Order value: 0.01 * 50000 = 500 USDT
      # Maker fee: 500 * 0.0003 = 0.15 USDT
      expected_fee = Decimal.new("0.15")
      # 10000 + 500 (unfreeze) - 0.15 (fee) - 500 (margin)
      expected_available = Decimal.new("9999.85")

      assert Decimal.equal?(new_balance.total_fees_paid, expected_fee)
      assert Decimal.equal?(new_balance.available, expected_available)
      # Unfrozen
      assert Decimal.equal?(new_balance.frozen, Decimal.new("0"))
      # New position margin
      assert Decimal.equal?(new_balance.margin_used, Decimal.new("500"))

      # Position should be created
      position = new_positions["BTCUSDT"]
      assert position != nil
      assert position.side == "long"
      assert Decimal.equal?(position.amount, Decimal.new("0.01"))
    end

    test "sell order reducing position still pays fees" do
      balance = %Balance{
        available: Decimal.new("9500"),
        # No frozen for position-reducing order
        frozen: Decimal.new("0"),
        margin_used: Decimal.new("500"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }

      # Existing long position
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

      # Market sell order to close position
      sell_order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "market",
        # Close entire position
        amount: Decimal.new("0.01"),
        # Exit at higher price
        price: Decimal.new("51000"),
        # No margin needed for position reduction
        frozen_amount: Decimal.new("0")
      }

      fill_price = Decimal.new("51000")

      {new_balance, new_positions} =
        ActionCalculator.calculate_action_effect(
          balance,
          positions,
          {:fill_order, sell_order, fill_price}
        )

      # Order value: 0.01 * 51000 = 510 USDT
      # Taker fee: 510 * 0.0005 = 0.255 USDT
      expected_fee = Decimal.new("0.255")
      # Realized profit: (51000 - 50000) * 0.01 = 10 USDT
      # Expected available: 9500 (start) + 0 (unfreeze) - 0.255 (fee) + 500 (released margin) + 10 (realized profit)
      # 9500 + 0 - 0.255 + 500 + 10
      expected_available = Decimal.new("10009.745")

      assert Decimal.equal?(new_balance.total_fees_paid, expected_fee)
      assert Decimal.equal?(new_balance.available, expected_available)
      # Position closed
      assert Decimal.equal?(new_balance.margin_used, Decimal.new("0"))

      # Position should be closed
      assert new_positions["BTCUSDT"] == nil
    end

    test "cumulative fee tracking across multiple trades" do
      balance = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("500"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }

      positions = %{}

      # First trade: market order
      market_order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.01"),
        price: Decimal.new("50000"),
        frozen_amount: Decimal.new("500")
      }

      {balance_after_first, positions_after_first} =
        ActionCalculator.calculate_action_effect(
          balance,
          positions,
          {:fill_order, market_order, Decimal.new("50000")}
        )

      # First fee: 500 * 0.0005 = 0.25
      assert Decimal.equal?(balance_after_first.total_fees_paid, Decimal.new("0.25"))

      # Second trade: sell order to close position
      sell_order = %Order{
        market: "BTCUSDT",
        side: "sell",
        type: "limit",
        amount: Decimal.new("0.01"),
        price: Decimal.new("51000"),
        frozen_amount: Decimal.new("0")
      }

      {balance_after_second, _} =
        ActionCalculator.calculate_action_effect(
          balance_after_first,
          positions_after_first,
          {:fill_order, sell_order, Decimal.new("51000")}
        )

      # Second fee: 510 * 0.0003 = 0.153
      # Total fees: 0.25 + 0.153 = 0.403
      expected_total_fees = Decimal.new("0.403")

      assert Decimal.equal?(balance_after_second.total_fees_paid, expected_total_fees)
    end

    test "fee calculation is purely transactional (order-independent)" do
      positions = %{}

      # Same order should always calculate same fee regardless of when/how it's called
      order = %Order{
        market: "BTCUSDT",
        side: "buy",
        type: "market",
        amount: Decimal.new("0.02"),
        price: Decimal.new("45000"),
        frozen_amount: Decimal.new("900")
      }

      balance1 = %Balance{
        available: Decimal.new("10000"),
        frozen: Decimal.new("900"),
        margin_used: Decimal.new("0"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        total_fees_paid: Decimal.new("0")
      }

      balance2 = %Balance{
        available: Decimal.new("8000"),
        frozen: Decimal.new("900"),
        margin_used: Decimal.new("1100"),
        total: Decimal.new("10000"),
        unrealized_pnl: Decimal.new("0"),
        # Different starting fees
        total_fees_paid: Decimal.new("50")
      }

      # Fill same order with different starting states
      {result1, _} =
        ActionCalculator.calculate_action_effect(
          balance1,
          positions,
          {:fill_order, order, Decimal.new("45000")}
        )

      {result2, _} =
        ActionCalculator.calculate_action_effect(
          balance2,
          positions,
          {:fill_order, order, Decimal.new("45000")}
        )

      # Fee calculation should be identical: 0.02 * 45000 * 0.0005 = 0.45
      expected_fee_increment = Decimal.new("0.45")

      fee1 = result1.total_fees_paid || Decimal.new("0")

      fee2_increment =
        Decimal.sub(
          result2.total_fees_paid || Decimal.new("0"),
          balance2.total_fees_paid || Decimal.new("0")
        )

      assert Decimal.equal?(fee1, expected_fee_increment)
      assert Decimal.equal?(fee2_increment, expected_fee_increment)
    end
  end
end
