defmodule Coinex.FuturesExchange do
  @moduledoc """
  A GenServer implementation that simulates CoinEx futures exchange API.
  Supports BTCUSDT market with order management, balance, and position tracking.
  """

  use GenServer
  require Logger

  alias Coinex.FuturesExchange.{Order, Position, Balance, ActionCalculator}

  @market "BTCUSDT"
  # Minimum order amount in BTC
  @minimum_order_amount Decimal.new("0.0001")

  # CoinEx Real Trading Fee Rates are now defined in ActionCalculator module

  defmodule State do
    defstruct [
      :current_price,
      # %{order_id => Order}
      :orders,
      # %{market => Position}
      :positions,
      # Balance struct
      :balance,
      :order_id_counter
    ]
  end

  defmodule Order do
    defstruct [
      :id,
      :market,
      # "buy" | "sell"
      :side,
      # "limit" | "market"
      :type,
      :amount,
      # nil for market orders
      :price,
      # "pending" | "filled" | "cancelled"
      :status,
      :filled_amount,
      :avg_price,
      :created_at,
      :updated_at,
      :client_id,
      # Amount frozen when order was placed
      :frozen_amount,
      # Fee rate applied (maker/taker)
      :fee_rate,
      # Actual fee charged
      :fee_amount,
      # Amount after fees (for filled orders)
      :net_amount
    ]
  end

  defmodule Position do
    defstruct [
      :market,
      # "long" | "short"
      :side,
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
      # Available balance in USDT
      :available,
      # Frozen balance (in orders)
      :frozen,
      # Used for positions
      :margin_used,
      # Total balance
      :total,
      # Unrealized PnL from positions
      :unrealized_pnl,
      # Cumulative fees paid (for analytics)
      :total_fees_paid
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

  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    initial_balance = %Balance{
      # Start with 10k USDT
      available: Decimal.new("10000.00"),
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
      order_id_counter: 1
    }

    # Subscribe to price updates from PricePoller (if available)
    # In test mode, PubSub might not be started, so we catch the error
    try do
      Phoenix.PubSub.subscribe(Coinex.PubSub, "price_updates:#{@market}")
    rescue
      ArgumentError ->
        # PubSub not available (e.g., in tests)
        :ok
    end

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
        {new_balance, new_positions} =
          ActionCalculator.calculate_action_effect(
            state.balance,
            state.positions,
            {:cancel_order, order}
          )

        # Delete the order instead of keeping it
        updated_order = %{order | status: "cancelled", updated_at: DateTime.utc_now()}
        new_orders = Map.delete(state.orders, order_id)

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
  def handle_call(:reset_state, _from, _state) do
    initial_balance = %Balance{
      # Start with 10k USDT
      available: Decimal.new("10000.00"),
      frozen: Decimal.new("0.00"),
      margin_used: Decimal.new("0.00"),
      total: Decimal.new("10000.00"),
      unrealized_pnl: Decimal.new("0.00")
    }

    new_state = %State{
      current_price: nil,
      orders: %{},
      positions: %{},
      balance: initial_balance,
      order_id_counter: 1
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:price_update, @market, price}, state) do
    Logger.info("Received price update for #{@market}: #{price}")
    new_state = %{state | current_price: price}

    # Update unrealized PnL for positions
    updated_state = update_positions_pnl(new_state)

    # Check and fill any pending limit orders that can now be executed
    final_state = check_and_fill_pending_orders(updated_state)

    {:noreply, final_state}
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

      decimal_price =
        if price do
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
        # Will be updated after calculation
        frozen_amount: Decimal.new("0")
      }

      # Set price for market orders using current price
      order_with_price =
        if type == "market" do
          %{order | price: state.current_price}
        else
          order
        end

      # Calculate frozen amount using pure function, considering pending orders
      frozen_amount =
        ActionCalculator.calculate_frozen_for_order(order_with_price, state.positions, state.orders)

      # Update order with the calculated frozen amount
      order_with_frozen = %{order_with_price | frozen_amount: frozen_amount}

      # Apply place_order action to get new balance and positions
      {new_balance, new_positions} =
        ActionCalculator.calculate_action_effect(
          state.balance,
          state.positions,
          {:place_order, order_with_frozen}
        )

      new_orders = Map.put(state.orders, order_id, order_with_frozen)

      new_state = %{
        state
        | orders: new_orders,
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
    # Create a temporary order to calculate position-aware frozen amount
    {:ok, decimal_amount} = safe_decimal_new(amount)

    decimal_price =
      case type do
        "limit" when not is_nil(price) ->
          {:ok, dp} = safe_decimal_new(price)
          dp

        "market" when not is_nil(state.current_price) ->
          state.current_price

        _ ->
          nil
      end

    # If we don't have a price yet, we can't validate properly
    if is_nil(decimal_price) do
      {:error, "Price not available"}
    else
      temp_order = %Order{
        market: @market,
        side: side,
        type: type,
        amount: decimal_amount,
        price: decimal_price
      }

      # Use ActionCalculator's position-aware frozen calculation, considering pending orders
      required_balance = ActionCalculator.calculate_frozen_for_order(temp_order, state.positions, state.orders)

      if Decimal.compare(state.balance.available, required_balance) != :lt do
        :ok
      else
        {:error, "Insufficient balance"}
      end
    end
  end

  defp process_order(state, %Order{type: "limit"} = order) do
    # For limit orders, check if they can be filled at current price
    # If immediately fillable, fill at current market price (like market order)
    # Otherwise, order remains pending until price reaches limit
    if can_fill_limit_order?(order, state.current_price) do
      # Fill at current market price
      fill_order_completely(state, order, state.current_price)
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
    filled_order = %{
      order
      | status: "filled",
        # Always fill the complete amount
        filled_amount: order.amount,
        avg_price: fill_price,
        updated_at: DateTime.utc_now()
    }

    # Apply fill_order action using pure function
    {new_balance, new_positions} =
      ActionCalculator.calculate_action_effect(
        state.balance,
        state.positions,
        {:fill_order, order, fill_price}
      )

    # Update orders
    new_orders = Map.put(state.orders, order.id, filled_order)

    new_state = %{state | orders: new_orders, positions: new_positions, balance: new_balance}

    {new_state, filled_order}
  end

  defp update_positions_pnl(state) when is_nil(state.current_price), do: state

  defp update_positions_pnl(state) do
    # Apply update_price action using pure function
    {new_balance, new_positions} =
      ActionCalculator.calculate_action_effect(
        state.balance,
        state.positions,
        {:update_price, state.current_price}
      )

    %{state | positions: new_positions, balance: new_balance}
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

  defp calculate_balance_with_margin(state) do
    # Calculate total margin used from all open positions
    total_margin_used =
      state.positions
      |> Map.values()
      |> Enum.reduce(Decimal.new("0"), fn position, acc ->
        Decimal.add(acc, position.margin_used)
      end)

    # Calculate total unrealized PnL from all positions
    total_unrealized_pnl =
      state.positions
      |> Map.values()
      |> Enum.reduce(Decimal.new("0"), fn position, acc ->
        Decimal.add(acc, position.unrealized_pnl)
      end)

    # Update balance with calculated values
    %{
      state.balance
      | margin_used: total_margin_used,
        unrealized_pnl: total_unrealized_pnl,
        total:
          Decimal.add(
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
      value_str =
        if is_float(value) do
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
