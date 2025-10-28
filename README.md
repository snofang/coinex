# CoinEx Futures Exchange Simulation

A Phoenix application implementing a simulated CoinEx futures exchange API using GenServer for state management.

## Features

- **Market Support**: BTCUSDT futures only (Linear Contracts, Isolated Margin)
- **Order Types**: Market and Limit orders (Buy/Sell)
- **Real-time Pricing**: Fetches live BTCUSDT price from CoinEx every minute
- **Position Management**: Long/Short position tracking with PnL calculation
- **Balance Management**: Available, frozen, and margin tracking
- **API Compatibility**: Matches real CoinEx API endpoints and response formats

## Architecture

### GenServer (`Coinex.FuturesExchange`)
- Maintains all state in memory (orders, positions, balance)
- Fetches real prices from CoinEx API every minute
- Handles order execution, position updates, and PnL calculations
- Started automatically with the application supervision tree

### Phoenix API (`CoinexWeb.FuturesController`)
- Provides HTTP endpoints matching CoinEx API signatures
- Returns JSON responses in CoinEx format with `code`, `message`, `data` structure

## API Endpoints

### Market Data
- `GET /perpetual/v1/market/ticker` - Current price and market info
- `GET /perpetual/v1/market/list` - Supported markets

### Order Management
- `POST /perpetual/v1/order/put_limit` - Place limit order
- `POST /perpetual/v1/order/put_market` - Place market order
- `POST /perpetual/v1/order/cancel` - Cancel order
- `GET /perpetual/v1/order/pending` - List pending orders
- `GET /perpetual/v1/order/finished` - List finished orders (filled/cancelled)

### Account Management
- `GET /perpetual/v1/position/pending` - List open positions
- `GET /perpetual/v1/asset/query` - Account balance

## Usage

### 🎮 **Web Trading Panel**
The easiest way to see the exchange in action is through the web interface:

1. **Start the server**: `mix phx.server`
2. **Open browser**: Visit `http://localhost:4000/trading`
3. **Interactive features**:
   - **Real-time updates** every 2 seconds
   - **Place orders**: Market and limit orders with live form
   - **Test price setting**: Override price to test limit order execution
   - **Live data**: Balance, orders, and positions update automatically
   - **Order management**: Cancel pending orders with one click

### Setup
```bash
# Install dependencies
mix deps.get

# Start the application
mix phx.server

# Visit the trading panel at http://localhost:4000/trading
# Or run the command-line demo
mix run demo.exs
```

### Example API Calls

```bash
# Check current price
curl http://localhost:4000/perpetual/v1/market/ticker

# Place limit buy order
curl -X POST http://localhost:4000/perpetual/v1/order/put_limit \
  -H "Content-Type: application/json" \
  -d '{
    "market": "BTCUSDT",
    "side": "buy", 
    "amount": "0.001",
    "price": "50000.0",
    "client_id": "my_order_1"
  }'

# Place market order
curl -X POST http://localhost:4000/perpetual/v1/order/put_market \
  -H "Content-Type: application/json" \
  -d '{
    "market": "BTCUSDT",
    "side": "buy",
    "amount": "0.001"
  }'

# Check balance
curl http://localhost:4000/perpetual/v1/asset/query

# Check positions
curl http://localhost:4000/perpetual/v1/position/pending

# List finished orders
curl "http://localhost:4000/perpetual/v1/order/finished"

# List finished orders with filters
curl "http://localhost:4000/perpetual/v1/order/finished?market=BTCUSDT&limit=10&offset=0"
```

### Programmatic Usage

```elixir
alias Coinex.FuturesExchange

# Check current price
FuturesExchange.get_current_price()

# Place orders
{:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.1", "50000.0")
{:ok, order} = FuturesExchange.submit_market_order("BTCUSDT", "sell", "0.1")

# Cancel order
{:ok, cancelled} = FuturesExchange.cancel_order(order.id)

# Check balance and positions
balance = FuturesExchange.get_balance()
positions = FuturesExchange.get_positions()
orders = FuturesExchange.get_orders()
```

## Initial Configuration

- **Starting Balance**: 10,000 USDT
- **Supported Market**: BTCUSDT only
- **Leverage**: Fixed at 1x (no leverage)
- **Price Updates**: Every 60 seconds from real CoinEx API

## Order Execution Logic

### Limit Orders (Simple Model)
- Created in "pending" status
- **Filled completely when price is "touched"** (no partial fills)
- Filled at the order price when conditions are met
- Checked for fulfillment on every price update

### Market Orders  
- **Executed immediately and completely** at current market price
- Require current price to be available
- Cannot be placed if no price data
- Always filled in full (no partial fills)

### Position Management
- Same-side orders increase position size
- Opposite-side orders reduce or reverse positions
- **Complete order amounts** affect positions (no partial impacts)
- Automatic PnL calculation based on current price
- Position closure when amounts net to zero

## Testing

```bash
# Run all tests
mix test

# Run specific test files
mix test test/coinex/futures_exchange_test.exs
mix test test/coinex_web/controllers/futures_controller_test.exs
```

The test suite includes:
- Order validation and creation
- Balance and position management  
- API endpoint functionality
- Error handling scenarios
- Price update mechanisms

## Limitations

- **Simple order model**: No partial fills - orders execute completely when price is touched
- Single market support (BTCUSDT only)
- No advanced order types (stop-loss, take-profit, etc.)
- Fixed 1x leverage
- In-memory state (data lost on restart)
- No user authentication/authorization
- No order history persistence

## Dependencies

- `decimal` - Precise decimal arithmetic for financial calculations
- `req` - HTTP client for fetching real market prices
- `meck` - Mocking library for tests
- Standard Phoenix/Elixir stack