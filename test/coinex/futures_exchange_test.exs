defmodule Coinex.FuturesExchangeTest do
  use ExUnit.Case, async: false

  alias Coinex.FuturesExchange

  setup do
    # Stop the GenServer if running and restart with clean state
    case Process.whereis(FuturesExchange) do
      nil -> 
        {:ok, _pid} = FuturesExchange.start_link([])
      pid -> 
        GenServer.stop(pid)
        {:ok, _pid} = FuturesExchange.start_link([])
    end
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
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.1", "50000.0", "client123")
      
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
      {:ok, _order2} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.2", "60000.0")
      
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
      assert Decimal.equal?(filled_order.filled_amount, Decimal.new("0.01"))  # Complete fill
      assert Decimal.equal?(filled_order.avg_price, Decimal.new("46000.0"))   # At order price
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
      assert Decimal.equal?(filled_order.filled_amount, Decimal.new("0.01"))  # Complete fill
      assert Decimal.equal?(filled_order.avg_price, Decimal.new("50000.0"))   # At order price
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
end