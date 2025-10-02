defmodule Coinex.FuturesExchange.ActionCalculator do
  @moduledoc """
  Pure function calculations for futures exchange actions.
  
  This module provides order-independent calculations for balance and position updates.
  Each function takes current balance + positions + action and returns new balance + positions.
  
  No dependencies on existing orders - all calculations are self-contained and deterministic.
  """

  alias Coinex.FuturesExchange.{Balance, Position, Order}
  
  # CoinEx Real Fee Rates (VIP 0 level)
  @maker_fee_rate Decimal.new("0.0003")    # 0.03% for limit orders
  @taker_fee_rate Decimal.new("0.0005")    # 0.05% for market orders

  @doc """
  Calculate the effect of an action on balance and positions.
  
  This is the main pure function that handles all state updates.
  
  ## Parameters
  - balance: Current balance state
  - positions: Map of current positions %{market => Position}
  - action: Action tuple to perform
  
  ## Returns
  {new_balance, new_positions}
  """
  @spec calculate_action_effect(Balance.t(), map(), action()) :: {Balance.t(), map()}
  def calculate_action_effect(balance, positions, action)

  def calculate_action_effect(balance, positions, {:place_order, order}) do
    frozen_amount = calculate_frozen_for_order(order, positions)
    
    updated_available = Decimal.sub(balance.available, frozen_amount)
    updated_frozen = Decimal.add(balance.frozen, frozen_amount)
    
    # Update total to maintain consistency: available + frozen + margin_used + unrealized_pnl
    updated_total = Decimal.add(
      Decimal.add(updated_available, updated_frozen),
      Decimal.add(balance.margin_used, balance.unrealized_pnl || Decimal.new("0"))
    )
    
    new_balance = %{balance |
      available: updated_available,
      frozen: updated_frozen,
      total: updated_total
    }
    
    {new_balance, positions}
  end

  def calculate_action_effect(balance, positions, {:cancel_order, order}) do
    # Unfreeze the exact amount that was frozen when order was placed
    frozen_amount = order.frozen_amount
    
    updated_available = Decimal.add(balance.available, frozen_amount)
    updated_frozen = Decimal.sub(balance.frozen, frozen_amount)
    
    # Update total to maintain consistency: available + frozen + margin_used + unrealized_pnl
    updated_total = Decimal.add(
      Decimal.add(updated_available, updated_frozen),
      Decimal.add(balance.margin_used, balance.unrealized_pnl || Decimal.new("0"))
    )
    
    new_balance = %{balance |
      available: updated_available,
      frozen: updated_frozen,
      total: updated_total
    }
    
    {new_balance, positions}
  end

  def calculate_action_effect(balance, positions, {:fill_order, order, fill_price}) do
    # Calculate CoinEx trading fees based purely on current action
    fee_rate = if order.type == "market", do: @taker_fee_rate, else: @maker_fee_rate
    order_value = Decimal.mult(order.amount, fill_price)
    fee_amount = Decimal.mult(order_value, fee_rate)

    # Transactional balance updates:
    # 1. Unfreeze the order amount (add back to available)
    # 2. Deduct the trading fee (subtract from available)
    # 3. Track cumulative fees paid
    after_unfreeze = Decimal.add(balance.available, order.frozen_amount)
    after_fee = Decimal.sub(after_unfreeze, fee_amount)

    new_balance = %{balance |
      frozen: Decimal.sub(balance.frozen, order.frozen_amount),
      available: after_fee,
      total_fees_paid: Decimal.add(balance.total_fees_paid || Decimal.new("0"), fee_amount)
    }

    # Update positions based on the order fill and calculate realized PnL
    {new_positions, realized_pnl} = update_position_for_fill(positions, order, fill_price)

    # Calculate margin changes due to position updates
    old_margin = calculate_total_margin_used(positions)
    new_margin = calculate_total_margin_used(new_positions)
    margin_change = Decimal.sub(new_margin, old_margin)

    # Adjust available balance for margin changes and realized PnL
    # If margin decreases (position reduction), available increases
    # If margin increases (position expansion), available decreases
    # Realized PnL is added to available balance when positions close/reduce
    final_available = new_balance.available
      |> Decimal.sub(margin_change)
      |> Decimal.add(realized_pnl)

    # Update total balance maintaining consistency
    final_total = Decimal.add(
      Decimal.add(final_available, new_balance.frozen),
      Decimal.add(new_margin, new_balance.unrealized_pnl || Decimal.new("0"))
    )

    final_balance = %{new_balance |
      available: final_available,
      margin_used: new_margin,
      total: final_total
    }

    {final_balance, new_positions}
  end

  def calculate_action_effect(balance, positions, {:update_price, new_price}) do
    # Update unrealized PnL for all positions
    updated_positions = update_positions_pnl(positions, new_price)
    
    # Calculate total unrealized PnL
    total_pnl = calculate_total_unrealized_pnl(updated_positions)
    
    new_balance = %{balance |
      unrealized_pnl: total_pnl,
      total: Decimal.add(Decimal.new("10000"), total_pnl)  # Base balance + PnL
    }
    
    {new_balance, updated_positions}
  end

  @doc """
  Calculate frozen amount needed for a new order.
  
  This is order-independent - only considers the order vs current positions.
  No dependency on existing pending orders.
  """
  @spec calculate_frozen_for_order(Order.t(), map()) :: Decimal.t()
  def calculate_frozen_for_order(order, positions) do
    price = get_order_price(order)
    position = Map.get(positions, order.market)
    
    if is_nil(price) do
      Decimal.new("0")
    else
      calculate_frozen_for_position_and_order(position, order, price)
    end
  end

  # Get effective price for order (order price for limit, current price for market)
  defp get_order_price(%Order{type: "limit", price: price}), do: price
  defp get_order_price(%Order{type: "market", price: price}), do: price  # Current price passed in
  
  # Calculate frozen amount based on position vs order
  defp calculate_frozen_for_position_and_order(nil, order, price) do
    # No existing position - need full margin for new position
    Decimal.mult(order.amount, price)
  end
  
  defp calculate_frozen_for_position_and_order(position, order, price) do
    order_side = if(order.side == "buy", do: "long", else: "short")
    
    cond do
      # Same side as position - increasing position, need full margin
      position.side == order_side ->
        Decimal.mult(order.amount, price)
      
      # Opposite side - reducing or reversing position
      position.side != order_side ->
        if Decimal.compare(order.amount, position.amount) == :gt do
          # Order exceeds position - margin needed for excess amount
          excess = Decimal.sub(order.amount, position.amount)
          Decimal.mult(excess, price)
        else
          # Order within position size - no additional margin needed
          Decimal.new("0")
        end
    end
  end

  # Update position after order fill
  # Returns {new_positions, realized_pnl}
  defp update_position_for_fill(positions, order, fill_price) do
    market = order.market
    existing_position = Map.get(positions, market)

    case existing_position do
      nil ->
        # Create new position - no realized PnL
        new_position = %Position{
          market: market,
          side: if(order.side == "buy", do: "long", else: "short"),
          amount: order.amount,
          entry_price: fill_price,
          unrealized_pnl: Decimal.new("0"),
          margin_used: Decimal.mult(order.amount, fill_price),
          leverage: Decimal.new("1"),
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        {Map.put(positions, market, new_position), Decimal.new("0")}

      position ->
        # Update existing position and calculate realized PnL
        {updated_position, realized_pnl} = merge_position_with_fill(position, order, fill_price)
        new_positions = if Decimal.equal?(updated_position.amount, Decimal.new("0")) do
          Map.delete(positions, market)
        else
          Map.put(positions, market, updated_position)
        end
        {new_positions, realized_pnl}
    end
  end

  # Merge existing position with order fill
  # Returns {updated_position, realized_pnl}
  defp merge_position_with_fill(position, order, fill_price) do
    order_side = if(order.side == "buy", do: "long", else: "short")

    if position.side == order_side do
      # Same side - increase position with weighted average entry price
      # No realized PnL when increasing position
      new_amount = Decimal.add(position.amount, order.amount)

      total_value = Decimal.add(
        Decimal.mult(position.amount, position.entry_price),
        Decimal.mult(order.amount, fill_price)
      )
      new_entry_price = Decimal.div(total_value, new_amount)

      updated_position = %{position |
        amount: new_amount,
        entry_price: new_entry_price,
        margin_used: Decimal.mult(new_amount, new_entry_price),
        updated_at: DateTime.utc_now()
      }
      {updated_position, Decimal.new("0")}
    else
      # Opposite side - reduce or reverse position
      # Calculate realized PnL for the closed portion
      closed_amount = Decimal.min(order.amount, position.amount)
      realized_pnl = calculate_realized_pnl(position, closed_amount, fill_price)

      if Decimal.compare(order.amount, position.amount) == :gt do
        # Reverse position - close existing and open new opposite position
        new_amount = Decimal.sub(order.amount, position.amount)
        updated_position = %{position |
          side: order_side,
          amount: new_amount,
          entry_price: fill_price,
          margin_used: Decimal.mult(new_amount, fill_price),
          updated_at: DateTime.utc_now()
        }
        {updated_position, realized_pnl}
      else
        # Reduce position - partial or complete close
        new_amount = Decimal.sub(position.amount, order.amount)
        updated_position = %{position |
          amount: new_amount,
          margin_used: Decimal.mult(new_amount, position.entry_price),
          updated_at: DateTime.utc_now()
        }
        {updated_position, realized_pnl}
      end
    end
  end

  # Calculate realized PnL when closing a position
  defp calculate_realized_pnl(position, closed_amount, exit_price) do
    # For long: profit = (exit_price - entry_price) * amount
    # For short: profit = (entry_price - exit_price) * amount
    price_diff = case position.side do
      "long" -> Decimal.sub(exit_price, position.entry_price)
      "short" -> Decimal.sub(position.entry_price, exit_price)
    end

    Decimal.mult(closed_amount, price_diff)
  end

  # Calculate total margin used across all positions
  defp calculate_total_margin_used(positions) do
    positions
    |> Map.values()
    |> Enum.map(& &1.margin_used)
    |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)
  end

  # Update PnL for all positions based on new price
  defp update_positions_pnl(positions, current_price) when is_nil(current_price), do: positions
  defp update_positions_pnl(positions, current_price) do
    Enum.into(positions, %{}, fn {market, position} ->
      if market == "BTCUSDT" do
        pnl = calculate_position_pnl(position, current_price)
        updated_position = %{position | unrealized_pnl: pnl, updated_at: DateTime.utc_now()}
        {market, updated_position}
      else
        {market, position}
      end
    end)
  end

  # Calculate unrealized PnL for a position
  defp calculate_position_pnl(position, current_price) do
    price_diff = case position.side do
      "long" -> Decimal.sub(current_price, position.entry_price)
      "short" -> Decimal.sub(position.entry_price, current_price)
    end
    
    Decimal.mult(position.amount, price_diff)
  end

  # Calculate total unrealized PnL across all positions
  defp calculate_total_unrealized_pnl(positions) do
    positions
    |> Map.values()
    |> Enum.map(& &1.unrealized_pnl)
    |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)
  end

  # Type specification for actions
  @type action :: 
    {:place_order, Order.t()} |
    {:cancel_order, Order.t()} |
    {:fill_order, Order.t(), Decimal.t()} |
    {:update_price, Decimal.t()}
end