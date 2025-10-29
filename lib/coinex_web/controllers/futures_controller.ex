defmodule CoinexWeb.FuturesController do
  use CoinexWeb, :controller

  alias Coinex.FuturesExchange

  # GET /perpetual/v1/market/ticker
  def ticker(conn, %{"market" => _market}) do
    case FuturesExchange.get_current_price() do
      nil ->
        json(conn, %{
          code: 1,
          message: "Price not available yet",
          data: nil
        })

      price ->
        json(conn, %{
          code: 0,
          message: "Ok",
          data: %{
            ticker: %{
              last: Decimal.to_string(price),
              # Simplified
              open: Decimal.to_string(price),
              # Simplified
              high: Decimal.to_string(price),
              # Simplified
              low: Decimal.to_string(price),
              vol: "0",
              amount: "0",
              period: 86400,
              funding_rate: "0.0001",
              funding_time: 28800,
              position_amount: "0",
              sign_price: Decimal.to_string(price),
              index_price: Decimal.to_string(price)
            }
          }
        })
    end
  end

  def ticker(conn, _params) do
    # Default to BTCUSDT if no market specified
    ticker(conn, %{"market" => "BTCUSDT"})
  end

  # POST /perpetual/v1/order/put_limit
  def put_limit_order(conn, params) do
    %{
      "market" => market,
      "side" => side,
      "amount" => amount,
      "price" => price
    } = params

    client_id = Map.get(params, "client_id")

    case FuturesExchange.submit_limit_order(market, side, amount, price, client_id) do
      {:ok, order} ->
        json(conn, %{
          code: 0,
          message: "Ok",
          data: serialize_order(order)
        })

      {:error, reason} ->
        json(conn, %{
          code: 1,
          message: reason,
          data: nil
        })
    end
  end

  # POST /perpetual/v1/order/put_market
  def put_market_order(conn, params) do
    %{
      "market" => market,
      "side" => side,
      "amount" => amount
    } = params

    client_id = Map.get(params, "client_id")

    case FuturesExchange.submit_market_order(market, side, amount, client_id) do
      {:ok, order} ->
        json(conn, %{
          code: 0,
          message: "Ok",
          data: serialize_order(order)
        })

      {:error, reason} ->
        json(conn, %{
          code: 1,
          message: reason,
          data: nil
        })
    end
  end

  # POST /perpetual/v1/order/cancel
  def cancel_order(conn, %{"order_id" => order_id}) do
    case FuturesExchange.cancel_order(String.to_integer(order_id)) do
      {:ok, order} ->
        json(conn, %{
          code: 0,
          message: "Ok",
          data: serialize_order(order)
        })

      {:error, reason} ->
        json(conn, %{
          code: 1,
          message: reason,
          data: nil
        })
    end
  end

  # GET /perpetual/v1/order/pending
  def pending_orders(conn, params) do
    orders = FuturesExchange.get_orders()
    pending_orders = Enum.filter(orders, &(&1.status == "pending"))

    # Apply market filter if provided
    filtered_orders =
      case Map.get(params, "market") do
        nil ->
          pending_orders

        market when is_binary(market) ->
          Enum.filter(pending_orders, &(&1.market == market))

        _ ->
          pending_orders
      end

    # Apply pagination with safe integer parsing
    offset = safe_parse_integer(Map.get(params, "offset", "0"), 0)
    limit = safe_parse_integer(Map.get(params, "limit", "20"), 20)

    # Ensure positive values and limit maximum records per request
    offset = max(offset, 0)
    limit = limit |> max(1) |> min(100)

    # Sort by created_at descending (newest first)
    sorted_orders = Enum.sort_by(filtered_orders, & &1.created_at, {:desc, DateTime})

    # Apply pagination
    paginated_orders =
      sorted_orders
      |> Enum.drop(offset)
      |> Enum.take(limit)

    json(conn, %{
      code: 0,
      message: "Ok",
      data: %{
        records: Enum.map(paginated_orders, &serialize_order/1),
        offset: offset,
        limit: limit
      }
    })
  end

  # GET /perpetual/v1/order/finished
  def finished_orders(conn, params) do
    # Get all orders and filter for finished ones
    orders = FuturesExchange.get_orders()

    finished_orders =
      Enum.filter(orders, fn order ->
        order.status == "filled"
      end)

    # Apply market filter if provided
    filtered_orders =
      case Map.get(params, "market") do
        nil ->
          finished_orders

        market when is_binary(market) ->
          Enum.filter(finished_orders, &(&1.market == market))

        _ ->
          finished_orders
      end

    # Apply side filter if provided (0: All, 1: Sell, 2: Buy)
    side_filtered_orders =
      case Map.get(params, "side") do
        nil ->
          filtered_orders

        "0" ->
          filtered_orders

        side_str when is_binary(side_str) ->
          case Integer.parse(side_str) do
            {side, ""} -> Enum.filter(filtered_orders, &(&1.side == side))
            _ -> filtered_orders
          end

        side when is_integer(side) ->
          Enum.filter(filtered_orders, &(&1.side == side))

        _ ->
          filtered_orders
      end

    # Apply time filtering if provided
    time_filtered_orders = apply_time_filters(side_filtered_orders, params)

    # Apply pagination with safe integer parsing
    offset = safe_parse_integer(Map.get(params, "offset", "0"), 0)
    limit = safe_parse_integer(Map.get(params, "limit", "20"), 20)

    # Ensure positive values and limit maximum records per request
    offset = max(offset, 0)
    limit = limit |> max(1) |> min(100)

    # Sort by created_at descending (newest first)
    sorted_orders = Enum.sort_by(time_filtered_orders, & &1.created_at, {:desc, DateTime})

    # Apply pagination
    paginated_orders =
      sorted_orders
      |> Enum.drop(offset)
      |> Enum.take(limit)

    json(conn, %{
      code: 0,
      message: "Ok",
      data: %{
        records: Enum.map(paginated_orders, &serialize_order/1),
        offset: offset,
        limit: limit
      }
    })
  end

  # GET /perpetual/v1/position/pending
  def pending_positions(conn, _params) do
    positions = FuturesExchange.get_positions()

    json(conn, %{
      code: 0,
      message: "Ok",
      data: Enum.map(positions, &serialize_position/1)
    })
  end

  # GET /perpetual/v1/asset/query
  def query_asset(conn, _params) do
    balance = FuturesExchange.get_balance()

    json(conn, %{
      code: 0,
      message: "Ok",
      data: %{
        "USDT" => %{
          available: format_decimal(balance.available),
          frozen: format_decimal(balance.frozen),
          # Not implemented
          transfer: "0.00",
          balance_total: format_decimal(balance.total),
          margin: format_decimal(balance.margin_used),
          profit_unreal: format_decimal(balance.unrealized_pnl || Decimal.new("0"))
        }
      }
    })
  end

  # GET /perpetual/v1/market/list
  def market_list(conn, _params) do
    json(conn, %{
      code: 0,
      message: "Ok",
      data: [
        %{
          name: "BTCUSDT",
          # Linear contract
          type: 1,
          stock: "BTC",
          money: "USDT",
          fee_prec: 4,
          stock_prec: 8,
          money_prec: 2,
          multiplier: "1",
          amount_min: "0.001",
          amount_max: "1000000",
          tick_size: "0.1",
          value_min: "1",
          value_max: "10000000",
          leverages: ["1", "2", "3", "5", "10", "20", "30", "50", "100"]
        }
      ]
    })
  end

  # Helper functions for serialization

  # Safely parse integer from string or integer, with default fallback
  defp safe_parse_integer(value, _default) when is_integer(value), do: value

  defp safe_parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp safe_parse_integer(_, default), do: default

  defp apply_time_filters(orders, params) do
    orders
    |> apply_start_time_filter(Map.get(params, "start_time"))
    |> apply_end_time_filter(Map.get(params, "end_time"))
  end

  defp apply_start_time_filter(orders, nil), do: orders

  defp apply_start_time_filter(orders, start_time_str) do
    start_time = String.to_integer(start_time_str) |> DateTime.from_unix!()

    Enum.filter(orders, fn order ->
      DateTime.compare(order.updated_at, start_time) != :lt
    end)
  end

  defp apply_end_time_filter(orders, nil), do: orders

  defp apply_end_time_filter(orders, end_time_str) do
    end_time = String.to_integer(end_time_str) |> DateTime.from_unix!()

    Enum.filter(orders, fn order ->
      DateTime.compare(order.updated_at, end_time) != :gt
    end)
  end

  defp serialize_order(order) do
    %{
      order_id: order.id,
      market: order.market,
      side: order.side,
      type: order.type,
      amount: Decimal.to_string(order.amount),
      price: if(order.price, do: Decimal.to_string(order.price), else: nil),
      status: order.status,
      filled_amount: Decimal.to_string(order.filled_amount),
      avg_price: if(order.avg_price, do: Decimal.to_string(order.avg_price), else: nil),
      created_at: DateTime.to_unix(order.created_at),
      updated_at: DateTime.to_unix(order.updated_at),
      client_id: order.client_id
    }
  end

  defp serialize_position(position) do
    %{
      market: position.market,
      side: position.side,
      amount: Decimal.to_string(position.amount),
      entry_price: Decimal.to_string(position.entry_price),
      unrealized_pnl: Decimal.to_string(position.unrealized_pnl),
      margin_used: Decimal.to_string(position.margin_used),
      leverage: Decimal.to_string(position.leverage),
      created_at: DateTime.to_unix(position.created_at),
      updated_at: DateTime.to_unix(position.updated_at)
    }
  end

  # Helper to format decimal with 2 decimal places
  defp format_decimal(decimal) do
    decimal
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
    |> ensure_two_decimals()
  end

  defp ensure_two_decimals(str) do
    case String.split(str, ".") do
      [integer] -> "#{integer}.00"
      [integer, decimal] when byte_size(decimal) == 1 -> "#{integer}.#{decimal}0"
      [integer, decimal] -> "#{integer}.#{String.slice(decimal, 0, 2)}"
    end
  end
end
