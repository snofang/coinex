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
              open: Decimal.to_string(price),  # Simplified
              high: Decimal.to_string(price),  # Simplified
              low: Decimal.to_string(price),   # Simplified
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
  def pending_orders(conn, _params) do
    orders = FuturesExchange.get_orders()
    pending_orders = Enum.filter(orders, & &1.status == "pending")
    
    json(conn, %{
      code: 0,
      message: "Ok",
      data: Enum.map(pending_orders, &serialize_order/1)
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
          available: Decimal.to_string(balance.available),
          frozen: Decimal.to_string(balance.frozen),
          transfer: "0",  # Not implemented
          balance_total: Decimal.to_string(balance.total),
          margin: Decimal.to_string(balance.margin_used),
          profit_unreal: Decimal.to_string(balance.unrealized_pnl)
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
          type: 1,  # Linear contract
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
end