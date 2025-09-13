defmodule Coinex.FuturesExchange do
  @moduledoc """
  A GenServer implementation that simulates CoinEx futures exchange API.
  Supports BTCUSDT market with order management, balance, and position tracking.
  """

  use GenServer
  require Logger

  alias Coinex.FuturesExchange.{Order, Position, Balance, ActionCalculator}

  @market "BTCUSDT"
  @price_update_interval 60_000  # 1 minute
  @minimum_order_amount Decimal.new("0.0001")  # Minimum order amount in BTC

  # CoinEx Real Trading Fee Rates (VIP 0 level)
  @maker_fee_rate Decimal.new("0.0003")    # 0.03% for limit orders (maker)
  @taker_fee_rate Decimal.new("0.0005")    # 0.05% for market orders (taker)

  defmodule State do
    defstruct [
      :current_price,
      :orders,           # %{order_id => Order}
      :positions,        # %{market => Position}
      :balance,          # Balance struct
      :order_id_counter,
      :price_update_timer
    ]
  end

  defmodule Order do
    defstruct [
      :id,
      :market,
      :side,              # "buy" | "sell"
      :type,              # "limit" | "market"
      :amount,
      :price,             # nil for market orders
      :status,            # "pending" | "filled" | "cancelled"
      :filled_amount,
      :avg_price,
      :created_at,
      :updated_at,
      :client_id,
      :frozen_amount,     # Amount frozen when order was placed
      :fee_rate,          # Fee rate applied (maker/taker)
      :fee_amount,        # Actual fee charged
      :net_amount         # Amount after fees (for filled orders)
    ]
  end

  defmodule Position do
    defstruct [
      :market,
      :side,              # "long" | "short"
      :amount,
      :entry_price,
      :unrealized_pnl,
      :margin_used,
      :leverage,
      :created_at,
      :updated_at
    ]
  end

  defmodule Balance do
    defstruct [
      :available,         # Available balance in USDT
      :frozen,           # Frozen balance (in orders)
      :margin_used,      # Used for positions
      :total,            # Total balance
      :unrealized_pnl,   # Unrealized PnL from positions
      :total_fees_paid   # Cumulative fees paid (for analytics)
    ]
  end

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_current_price do
    GenServer.call(__MODULE__, :get_current_price)
  end

  # Test helper to manually set price
  def set_current_price(price) do
    GenServer.call(__MODULE__, {:set_current_price, price})
  end

  def submit_limit_order(market, side, amount, price, client_id \\ nil) do
    GenServer.call(__MODULE__, {:submit_limit_order, market, side, amount, price, client_id})
  end

  def submit_market_order(market, side, amount, client_id \\ nil) do
    GenServer.call(__MODULE__, {:submit_market_order, market, side, amount, client_id})
  end

  def cancel_order(order_id) do
    GenServer.call(__MODULE__, {:cancel_order, order_id})
  end

  def get_orders do
    GenServer.call(__MODULE__, :get_orders)
  end

  def get_positions do
    GenServer.call(__MODULE__, :get_positions)
  end

  def get_balance do
    GenServer.call(__MODULE__, :get_balance)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    initial_balance = %Balance{
      available: Decimal.new("10000.00"),    # Start with 10k USDT
      frozen: Decimal.new("0.00"),
      margin_used: Decimal.new("0.00"),
      total: Decimal.new("10000.00"),
      unrealized_pnl: Decimal.new("0.00")
    }

    state = %State{
      current_price: nil,
      orders: %{},
      positions: %{},
      balance: initial_balance,
      order_id_counter: 1,
      price_update_timer: nil
    }

    # Start price fetching immediately
    send(self(), :fetch_price)
    
    {:ok, state}
  end

  @impl true
  def handle_call(:get_current_price, _from, state) do
    {:reply, state.current_price, state}
  end

  @impl true
  def handle_call({:set_current_price, price}, _from, state) do
    new_state = %{state | current_price: price}
    
    # Update unrealized PnL for positions
    updated_state = update_positions_pnl(new_state)
    
    # Check and fill any pending limit orders that can now be executed
    final_state = check_and_fill_pending_orders(updated_state)
    
    {:reply, :ok, final_state}
  end

  @impl true
  def handle_call({:submit_limit_order, market, side, amount, price, client_id}, _from, state) do
    if market != @market do
      {:reply, {:error, "Unsupported market"}, state}
    else
      case validate_and_create_order(state, market, side, amount, price, "limit", client_id) do
        {:ok, order, new_state} ->
          # Process the order (check if it can be filled immediately)
          {final_state, order_response} = process_order(new_state, order)
          {:reply, {:ok, order_response}, final_state}
        
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:submit_market_order, market, side, amount, client_id}, _from, state) do
    if market != @market do
      {:reply, {:error, "Unsupported market"}, state}
    else
      if is_nil(state.current_price) do
        {:reply, {:error, "Price not available"}, state}
      else
        case validate_and_create_order(state, market, side, amount, nil, "market", client_id) do
          {:ok, order, new_state} ->
            # Market orders are filled immediately at current price
            {final_state, order_response} = fill_market_order(new_state, order)
            {:reply, {:ok, order_response}, final_state}
          
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end
    end
  end

  @impl true
  def handle_call({:cancel_order, order_id}, _from, state) do
    case Map.get(state.orders, order_id) do
      nil ->
        {:reply, {:error, "Order not found"}, state}
      
      %Order{status: status} when status in ["filled", "cancelled"] ->
        {:reply, {:error, "Order cannot be cancelled"}, state}
      
      order ->
        # Apply cancel_order action using pure function
        {new_balance, new_positions} = ActionCalculator.calculate_action_effect(
          state.balance,
          state.positions,
          {:cancel_order, order}
        )
        
        updated_order = %{order | status: "cancelled", updated_at: DateTime.utc_now()}
        new_orders = Map.put(state.orders, order_id, updated_order)
        
        new_state = %{state | orders: new_orders, balance: new_balance, positions: new_positions}
        {:reply, {:ok, updated_order}, new_state}
    end
  end

  @impl true
  def handle_call(:get_orders, _from, state) do
    {:reply, Map.values(state.orders), state}
  end

  @impl true
  def handle_call(:get_positions, _from, state) do
    {:reply, Map.values(state.positions), state}
  end

  @impl true
  def handle_call(:get_balance, _from, state) do
    balance_with_margin = calculate_balance_with_margin(state)
    {:reply, balance_with_margin, state}
  end

  @impl true
  def handle_info(:fetch_price, state) do
    # Fetch price from real CoinEx API
    case fetch_coinex_price() do
      {:ok, price} ->
        Logger.info("Updated BTCUSDT price: #{price}")
        new_state = %{state | current_price: price}
        
        # Update unrealized PnL for positions
        updated_state = update_positions_pnl(new_state)
        
        # Check and fill any pending limit orders that can now be executed
        # Simple model: when price is touched, orders are filled completely
        final_state = check_and_fill_pending_orders(updated_state)
        
        # Schedule next price update
        timer_ref = Process.send_after(self(), :fetch_price, @price_update_interval)
        final_final_state = %{final_state | price_update_timer: timer_ref}
        
        {:noreply, final_final_state}
      
      {:error, reason} ->
        Logger.error("Failed to fetch price: #{inspect(reason)}")
        # Retry in 10 seconds
        timer_ref = Process.send_after(self(), :fetch_price, 10_000)
        {:noreply, %{state | price_update_timer: timer_ref}}
    end
  end

  ## Private Functions

  defp validate_and_create_order(state, market, side, amount, price, type, client_id) do
    with :ok <- validate_market(market),
         :ok <- validate_side(side),
         :ok <- validate_amount(amount),
         :ok <- validate_price(price, type),
         :ok <- validate_balance(state, side, amount, price, type) do
      
      order_id = state.order_id_counter
      now = DateTime.utc_now()
      
      {:ok, decimal_amount} = safe_decimal_new(amount)
      decimal_price = if price do
        {:ok, dp} = safe_decimal_new(price)
        dp
      else
        nil
      end
      
      order = %Order{
        id: order_id,
        market: market,
        side: side,
        type: type,
        amount: decimal_amount,
        price: decimal_price,
        status: "pending",
        filled_amount: Decimal.new("0"),
        avg_price: nil,
        created_at: now,
        updated_at: now,
        client_id: client_id,
        frozen_amount: Decimal.new("0")  # Will be updated after calculation
      }
      
      # Set price for market orders using current price
      order_with_price = if type == "market" do
        %{order | price: state.current_price}
      else
        order
      end
      
      # Calculate frozen amount using pure function
      frozen_amount = ActionCalculator.calculate_frozen_for_order(order_with_price, state.positions)
      
      # Update order with the calculated frozen amount
      order_with_frozen = %{order_with_price | frozen_amount: frozen_amount}
      
      # Apply place_order action to get new balance and positions
      {new_balance, new_positions} = ActionCalculator.calculate_action_effect(
        state.balance, 
        state.positions, 
        {:place_order, order_with_frozen}
      )
      
      new_orders = Map.put(state.orders, order_id, order_with_frozen)
      new_state = %{state | 
        orders: new_orders,
        order_id_counter: order_id + 1,
        balance: new_balance,
        positions: new_positions
      }
      
      {:ok, order_with_frozen, new_state}
    end
  end

  defp validate_market(@market), do: :ok
  defp validate_market(_), do: {:error, "Invalid market"}

  defp validate_side(side) when side in ["buy", "sell"], do: :ok
  defp validate_side(_), do: {:error, "Invalid side"}

  defp validate_amount(amount) when is_binary(amount) or is_number(amount) do
    case safe_decimal_new(amount) do
      {:ok, decimal} ->
        cond do
          not Decimal.positive?(decimal) -> 
            {:error, "Amount must be positive"}
          Decimal.compare(decimal, @minimum_order_amount) == :lt -> 
            {:error, "Amount must be at least #{@minimum_order_amount} BTC"}
          true -> 
            :ok
        end
      {:error, _reason} ->
        {:error, "Invalid amount"}
    end
  end
  defp validate_amount(_), do: {:error, "Invalid amount"}

  defp validate_price(nil, "market"), do: :ok
  defp validate_price(price, "limit") when is_binary(price) or is_number(price) do
    case Decimal.new(price) do
      %Decimal{} = decimal ->
        if Decimal.positive?(decimal), do: :ok, else: {:error, "Price must be positive"}
      _ ->
        {:error, "Invalid price"}
    end
  end
  defp validate_price(_, _), do: {:error, "Invalid price"}

  defp validate_balance(state, side, amount, price, type) do
    required_balance = calculate_required_balance(side, amount, price, type, state.current_price)
    
    if Decimal.compare(state.balance.available, required_balance) != :lt do
      :ok
    else
      {:error, "Insufficient balance"}
    end
  end

  defp calculate_required_balance("buy", amount, price, "limit", _current_price) do
    {:ok, decimal_amount} = safe_decimal_new(amount)
    {:ok, decimal_price} = safe_decimal_new(price)
    Decimal.mult(decimal_amount, decimal_price)
  end
  defp calculate_required_balance("buy", amount, nil, "market", current_price) when not is_nil(current_price) do
    # For market buy orders, estimate using current price
    {:ok, decimal_amount} = safe_decimal_new(amount)
    Decimal.mult(decimal_amount, current_price)
  end
  defp calculate_required_balance("buy", _amount, nil, "market", nil) do
    # For market buy orders without current price, return zero (will be validated later)
    Decimal.new("0")
  end
  defp calculate_required_balance("sell", _amount, _price, _type, _current_price) do
    # For sell orders, we need to check position or available assets
    # For simplicity, assume no balance required for sell orders in futures
    Decimal.new("0")
  end
  defp calculate_required_balance(_, _, _, _, _), do: Decimal.new("0")

  defp freeze_funds_for_order(balance, order, current_price, positions, orders) do
    # When placing a new order, exclude it from the effective position calculation
    frozen_amount = calculate_order_frozen_amount(order, current_price, positions, orders, order.id)
    
    new_balance = %{balance |
      available: Decimal.sub(balance.available, frozen_amount),
      frozen: Decimal.add(balance.frozen, frozen_amount)
    }
    
    {frozen_amount, new_balance}
  end

  # Get current net position for a market, considering pending orders (excluding current order)
  defp get_effective_net_position(positions, orders, market, exclude_order_id \\ nil) do
    # Start with actual position
    {position_side, position_amount} = case Map.get(positions, market) do
      nil -> {:none, Decimal.new("0")}
      %Position{side: "long", amount: amount} -> {:long, amount}
      %Position{side: "short", amount: amount} -> {:short, amount}
    end
    
    # Calculate pending order impact, excluding the order currently being placed
    pending_orders = orders
    |> Map.values()
    |> Enum.filter(&(&1.status == "pending" && &1.market == market && &1.id != exclude_order_id))
    
    # Sum up pending buy and sell amounts
    {pending_buys, pending_sells} = Enum.reduce(pending_orders, {Decimal.new("0"), Decimal.new("0")}, fn order, {buys, sells} ->
      case order.side do
        "buy" -> {Decimal.add(buys, order.amount), sells}
        "sell" -> {buys, Decimal.add(sells, order.amount)}
      end
    end)
    
    # Calculate effective position after pending orders
    calculate_effective_position(position_side, position_amount, pending_buys, pending_sells)
  end

  defp calculate_effective_position(position_side, position_amount, pending_buys, pending_sells) do
    net_pending = Decimal.sub(pending_buys, pending_sells)
    
    case position_side do
      :none ->
        cond do
          Decimal.positive?(net_pending) -> {:long, net_pending}
          Decimal.negative?(net_pending) -> {:short, Decimal.abs(net_pending)}
          true -> {:none, Decimal.new("0")}
        end
      
      :long ->
        new_amount = Decimal.add(position_amount, net_pending)
        cond do
          Decimal.positive?(new_amount) -> {:long, new_amount}
          Decimal.negative?(new_amount) -> {:short, Decimal.abs(new_amount)}
          true -> {:none, Decimal.new("0")}
        end
      
      :short ->
        new_amount = Decimal.sub(net_pending, position_amount)  # net_pending - short_amount
        cond do
          Decimal.positive?(new_amount) -> {:long, new_amount}
          Decimal.negative?(new_amount) -> {:short, Decimal.abs(new_amount)}
          true -> {:none, Decimal.new("0")}
        end
    end
  end

  # Position-aware frozen amount calculation
  defp calculate_order_frozen_amount(order, current_price, positions, orders, exclude_order_id \\ nil) do
    price = case order.type do
      "limit" -> order.price
      "market" when not is_nil(current_price) -> current_price
      "market" when is_nil(current_price) -> nil
    end

    if is_nil(price) do
      Decimal.new("0")
    else
      {position_side, position_amount} = get_effective_net_position(positions, orders, order.market, exclude_order_id)
      calculate_margin_for_new_exposure(order.side, order.amount, position_side, position_amount, price)
    end
  end

  # Calculate margin needed for new position exposure
  defp calculate_margin_for_new_exposure(order_side, order_amount, position_side, position_amount, price) do
    case {position_side, order_side} do
      # No existing position - need full margin
      {:none, _} -> 
        Decimal.mult(order_amount, price)
      
      # Same side - increasing position, need full margin
      {:long, "buy"} -> 
        Decimal.mult(order_amount, price)
      {:short, "sell"} -> 
        Decimal.mult(order_amount, price)
      
      # Opposite side - reducing position or reversing
      {:long, "sell"} ->
        if Decimal.compare(order_amount, position_amount) == :gt do
          # Order exceeds position - margin needed for excess (new short)
          excess = Decimal.sub(order_amount, position_amount)
          Decimal.mult(excess, price)
        else
          # Order within position - no additional margin needed
          Decimal.new("0")
        end
      
      {:short, "buy"} ->
        if Decimal.compare(order_amount, position_amount) == :gt do
          # Order exceeds position - margin needed for excess (new long)
          excess = Decimal.sub(order_amount, position_amount)
          Decimal.mult(excess, price)
        else
          # Order within position - no additional margin needed
          Decimal.new("0")
        end
    end
  end

  defp process_order(state, %Order{type: "limit"} = order) do
    # For limit orders, check if they can be filled at current price
    # Simple model: orders are filled completely when price is touched
    if can_fill_limit_order?(order, state.current_price) do
      fill_order_completely(state, order, order.price)  # Fill at order price, not current price
    else
      # Order remains pending
      {state, order}
    end
  end

  defp fill_market_order(state, order) do
    # Market orders are filled completely at current price
    fill_order_completely(state, order, state.current_price)
  end

  defp can_fill_limit_order?(%Order{side: "buy", price: price}, current_price) do
    # Buy order fills when current price is at or below the order price
    not is_nil(current_price) and Decimal.compare(current_price, price) != :gt
  end
  defp can_fill_limit_order?(%Order{side: "sell", price: price}, current_price) do
    # Sell order fills when current price is at or above the order price  
    not is_nil(current_price) and Decimal.compare(current_price, price) != :lt
  end

  defp fill_order_completely(state, order, fill_price) do
    # Simple model: orders are always filled completely, no partial fills
    filled_order = %{order |
      status: "filled",
      filled_amount: order.amount,  # Always fill the complete amount
      avg_price: fill_price,
      updated_at: DateTime.utc_now()
    }
    
    # Apply fill_order action using pure function
    {new_balance, new_positions} = ActionCalculator.calculate_action_effect(
      state.balance,
      state.positions,
      {:fill_order, order, fill_price}
    )
    
    # Update orders
    new_orders = Map.put(state.orders, order.id, filled_order)
    
    new_state = %{state |
      orders: new_orders,
      positions: new_positions,
      balance: new_balance
    }
    
    {new_state, filled_order}
  end

  defp update_position_after_complete_fill(positions, order, fill_price) do
    position_key = order.market
    existing_position = Map.get(positions, position_key)
    
    case existing_position do
      nil ->
        # Create new position
        new_position = %Position{
          market: order.market,
          side: if(order.side == "buy", do: "long", else: "short"),
          amount: order.amount,
          entry_price: fill_price,
          unrealized_pnl: Decimal.new("0"),
          margin_used: calculate_margin_used(order.amount, fill_price),
          leverage: Decimal.new("1"),  # Default leverage
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Map.put(positions, position_key, new_position)
      
      position ->
        # Update existing position
        updated_position = merge_position_with_order(position, order, fill_price)
        if Decimal.equal?(updated_position.amount, Decimal.new("0")) do
          Map.delete(positions, position_key)
        else
          Map.put(positions, position_key, updated_position)
        end
    end
  end

  defp calculate_margin_used(amount, price) do
    # Simple calculation: amount * price (no leverage applied)
    Decimal.mult(amount, price)
  end

  defp merge_position_with_order(position, order, fill_price) do
    order_side = if(order.side == "buy", do: "long", else: "short")
    
    if position.side == order_side do
      # Same side - increase position
      new_amount = Decimal.add(position.amount, order.amount)
      total_value = Decimal.add(
        Decimal.mult(position.amount, position.entry_price),
        Decimal.mult(order.amount, fill_price)
      )
      new_entry_price = Decimal.div(total_value, new_amount)
      
      %{position |
        amount: new_amount,
        entry_price: new_entry_price,
        margin_used: calculate_margin_used(new_amount, new_entry_price),
        updated_at: DateTime.utc_now()
      }
    else
      # Opposite side - reduce or reverse position
      if Decimal.compare(order.amount, position.amount) == :gt do
        # Reverse position
        new_amount = Decimal.sub(order.amount, position.amount)
        %{position |
          side: order_side,
          amount: new_amount,
          entry_price: fill_price,
          margin_used: calculate_margin_used(new_amount, fill_price),
          updated_at: DateTime.utc_now()
        }
      else
        # Reduce position
        new_amount = Decimal.sub(position.amount, order.amount)
        %{position |
          amount: new_amount,
          margin_used: calculate_margin_used(new_amount, position.entry_price),
          updated_at: DateTime.utc_now()
        }
      end
    end
  end

  defp update_balance_after_complete_fill(balance, order, _fill_price, _positions, _orders) do
    # Use stored frozen amount instead of recalculating
    frozen_amount = order.frozen_amount
    
    %{balance |
      frozen: Decimal.sub(balance.frozen, frozen_amount)
    }
  end

  defp update_positions_pnl(state) when is_nil(state.current_price), do: state
  defp update_positions_pnl(state) do
    # Apply update_price action using pure function
    {new_balance, new_positions} = ActionCalculator.calculate_action_effect(
      state.balance,
      state.positions,
      {:update_price, state.current_price}
    )
    
    %{state | positions: new_positions, balance: new_balance}
  end

  defp calculate_position_pnl(position, current_price) do
    pnl = case position.side do
      "long" ->
        Decimal.mult(
          position.amount,
          Decimal.sub(current_price, position.entry_price)
        )
      "short" ->
        Decimal.mult(
          position.amount,
          Decimal.sub(position.entry_price, current_price)
        )
    end
    
    %{position | unrealized_pnl: pnl, updated_at: DateTime.utc_now()}
  end

  defp check_and_fill_pending_orders(state) do
    # Find all pending limit orders that can now be filled
    pending_orders = 
      state.orders
      |> Map.values()
      |> Enum.filter(&(&1.status == "pending" and &1.type == "limit"))
    
    # Process each pending order that can be filled
    Enum.reduce(pending_orders, state, fn order, acc_state ->
      if can_fill_limit_order?(order, acc_state.current_price) do
        # Fill the order completely at the order price (simple model)
        {updated_state, _filled_order} = fill_order_completely(acc_state, order, order.price)
        Logger.info("Filled pending order #{order.id} at price #{Decimal.to_string(order.price)}")
        updated_state
      else
        acc_state
      end
    end)
  end

  def fetch_coinex_price do
    # Using CoinEx public API to get current BTCUSDT futures price
    url = "https://api.coinex.com/perpetual/v1/market/ticker?market=BTCUSDT"
    
    case Req.get(url) do
      {:ok, %{status: 200, body: %{"code" => 0, "data" => data}}} ->
        price = data["ticker"]["last"]
        {:ok, Decimal.new(price)}
      
      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp calculate_balance_with_margin(state) do
    # Calculate total margin used from all open positions
    total_margin_used = state.positions
    |> Map.values()
    |> Enum.reduce(Decimal.new("0"), fn position, acc ->
      Decimal.add(acc, position.margin_used)
    end)

    # Calculate total unrealized PnL from all positions
    total_unrealized_pnl = state.positions
    |> Map.values()
    |> Enum.reduce(Decimal.new("0"), fn position, acc ->
      Decimal.add(acc, position.unrealized_pnl)
    end)

    # Update balance with calculated values
    %{state.balance |
      margin_used: total_margin_used,
      unrealized_pnl: total_unrealized_pnl,
      total: Decimal.add(
        Decimal.add(state.balance.available, state.balance.frozen),
        total_unrealized_pnl
      )
    }
  end

  # Helper function to safely convert numbers/strings to Decimal
  defp safe_decimal_new(value) when is_binary(value) do
    try do
      {:ok, Decimal.new(value)}
    rescue
      _ -> {:error, "Invalid decimal format"}
    end
  end
  
  defp safe_decimal_new(value) when is_number(value) do
    try do
      # Convert to string first to handle scientific notation and floats
      value_str = if is_float(value) do
        :erlang.float_to_binary(value, [:compact])
      else
        Integer.to_string(value)
      end
      {:ok, Decimal.new(value_str)}
    rescue
      _ -> {:error, "Invalid decimal format"}
    end
  end
  
  defp safe_decimal_new(_), do: {:error, "Invalid decimal format"}
end