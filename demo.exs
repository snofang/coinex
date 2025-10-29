# Demo script showing the CoinEx Futures Exchange implementation
# Run with: mix run demo.exs

alias Coinex.FuturesExchange

IO.puts("=== CoinEx Futures Exchange Demo ===")

# Start the application if not already running
Application.ensure_all_started(:coinex)

# Wait for price to be fetched
:timer.sleep(2000)

IO.puts("\n1. Check current price:")
price = FuturesExchange.get_current_price()

if price do
  IO.puts("Current BTCUSDT price: #{Decimal.to_string(price)}")
else
  IO.puts("Price not available yet (will retry in a minute)")
end

IO.puts("\n2. Check initial balance:")
balance = FuturesExchange.get_balance()
IO.puts("Available: #{Decimal.to_string(balance.available)} USDT")
IO.puts("Frozen: #{Decimal.to_string(balance.frozen)} USDT")
IO.puts("Total: #{Decimal.to_string(balance.total)} USDT")

IO.puts("\n3. Place a limit buy order:")

case FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.001", "45000", "demo_order_1") do
  {:ok, order} ->
    IO.puts(
      "✓ Limit order created: #{order.id} - #{order.side} #{Decimal.to_string(order.amount)} at $#{Decimal.to_string(order.price)}"
    )

    IO.puts(
      "  Note: This order will be filled completely when price touches $45,000 (simple model - no partial fills)"
    )

  {:error, reason} ->
    IO.puts("✗ Failed to create order: #{reason}")
end

IO.puts("\n4. Check balance after order:")
balance = FuturesExchange.get_balance()
IO.puts("Available: #{Decimal.to_string(balance.available)} USDT")
IO.puts("Frozen: #{Decimal.to_string(balance.frozen)} USDT")

IO.puts("\n5. Place a market buy order (if price available):")

if price do
  case FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.001", "demo_market_1") do
    {:ok, order} ->
      IO.puts(
        "✓ Market order executed completely: #{order.side} #{Decimal.to_string(order.filled_amount)} at $#{Decimal.to_string(order.avg_price)}"
      )

      IO.puts(
        "  Note: Market orders are always filled in full at current price (no partial fills)"
      )

    {:error, reason} ->
      IO.puts("✗ Failed to execute market order: #{reason}")
  end
else
  IO.puts("⚠ Market order skipped - no price available")
end

IO.puts("\n6. Check current positions:")
positions = FuturesExchange.get_positions()

if positions == [] do
  IO.puts("No open positions")
else
  for position <- positions do
    IO.puts(
      "Position: #{position.side} #{Decimal.to_string(position.amount)} #{position.market} @ $#{Decimal.to_string(position.entry_price)}"
    )

    IO.puts("Unrealized PnL: #{Decimal.to_string(position.unrealized_pnl)} USDT")
  end
end

IO.puts("\n7. List all orders:")
orders = FuturesExchange.get_orders()

if orders == [] do
  IO.puts("No orders")
else
  for order <- orders do
    IO.puts(
      "Order #{order.id}: #{order.side} #{order.type} #{Decimal.to_string(order.amount)} #{order.market} - Status: #{order.status}"
    )

    if order.price, do: IO.puts("  Price: $#{Decimal.to_string(order.price)}")
    if order.client_id, do: IO.puts("  Client ID: #{order.client_id}")
  end
end

IO.puts("\n8. Cancel pending orders:")
pending_orders = Enum.filter(orders, &(&1.status == "pending"))

for order <- pending_orders do
  case FuturesExchange.cancel_order(order.id) do
    {:ok, cancelled_order} ->
      IO.puts("✓ Cancelled order #{cancelled_order.id}")

    {:error, reason} ->
      IO.puts("✗ Failed to cancel order #{order.id}: #{reason}")
  end
end

IO.puts("\n9. Final balance:")
balance = FuturesExchange.get_balance()
IO.puts("Available: #{Decimal.to_string(balance.available)} USDT")
IO.puts("Frozen: #{Decimal.to_string(balance.frozen)} USDT")
IO.puts("Margin Used: #{Decimal.to_string(balance.margin_used)} USDT")
IO.puts("Unrealized PnL: #{Decimal.to_string(balance.unrealized_pnl)} USDT")
IO.puts("Total: #{Decimal.to_string(balance.total)} USDT")

IO.puts("\n=== Demo Complete ===")
IO.puts("\nAPI endpoints are available at:")
IO.puts("- GET /perpetual/v1/market/ticker - Get current price")
IO.puts("- POST /perpetual/v1/order/put_limit - Place limit order")
IO.puts("- POST /perpetual/v1/order/put_market - Place market order")
IO.puts("- POST /perpetual/v1/order/cancel - Cancel order")
IO.puts("- GET /perpetual/v1/order/pending - List pending orders")
IO.puts("- GET /perpetual/v1/position/pending - List positions")
IO.puts("- GET /perpetual/v1/asset/query - Get balance")
IO.puts("- GET /perpetual/v1/market/list - List supported markets")
