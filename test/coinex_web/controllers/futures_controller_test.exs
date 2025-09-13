defmodule CoinexWeb.FuturesControllerTest do
  use ExUnit.Case, async: false
  use Phoenix.ConnTest

  alias Coinex.FuturesExchange

  @endpoint CoinexWeb.Endpoint

  setup do
    # Restart the GenServer with clean state for each test
    if Process.whereis(FuturesExchange) do
      GenServer.stop(FuturesExchange)
    end
    
    {:ok, _pid} = FuturesExchange.start_link([])
    :ok
  end

  describe "GET /perpetual/v1/market/ticker" do
    test "returns price not available when no price set" do
      conn = build_conn()
      conn = get(conn, "/perpetual/v1/market/ticker")
      
      assert json_response(conn, 200) == %{
        "code" => 1,
        "message" => "Price not available yet",
        "data" => nil
      }
    end

    test "returns ticker data when price is available" do
      # Mock price update
      :meck.new(Coinex.FuturesExchange, [:passthrough])
      :meck.expect(Coinex.FuturesExchange, :fetch_coinex_price, fn -> 
        {:ok, Decimal.new("50000.0")}
      end)
      
      send(Process.whereis(FuturesExchange), :fetch_price)
      :timer.sleep(100)
      
      conn = build_conn()
      conn = get(conn, "/perpetual/v1/market/ticker")
      
      response = json_response(conn, 200)
      assert response["code"] == 0
      assert response["message"] == "Ok"
      assert response["data"]["ticker"]["last"] == "50000.0"
      
      :meck.unload(Coinex.FuturesExchange)
    end

    test "accepts market parameter" do
      conn = build_conn()
      conn = get(conn, "/perpetual/v1/market/ticker?market=BTCUSDT")
      
      response = json_response(conn, 200)
      # Should handle the request (price not available initially)
      assert response["code"] == 1
    end
  end

  describe "POST /perpetual/v1/order/put_limit" do
    test "successfully creates limit order" do
      params = %{
        "market" => "BTCUSDT",
        "side" => "buy",
        "amount" => "0.1",
        "price" => "50000.0",
        "client_id" => "test123"
      }
      
      conn = build_conn()
      conn = post(conn, "/perpetual/v1/order/put_limit", params)
      
      response = json_response(conn, 200)
      assert response["code"] == 0
      assert response["message"] == "Ok"
      
      order_data = response["data"]
      assert order_data["order_id"] == 1
      assert order_data["market"] == "BTCUSDT"
      assert order_data["side"] == "buy"
      assert order_data["type"] == "limit"
      assert order_data["amount"] == "0.1"
      assert order_data["price"] == "50000.0"
      assert order_data["status"] == "pending"
      assert order_data["client_id"] == "test123"
    end

    test "returns error for invalid market" do
      params = %{
        "market" => "ETHUSDT",
        "side" => "buy",
        "amount" => "0.1",
        "price" => "50000.0"
      }
      
      conn = build_conn()
      conn = post(conn, "/perpetual/v1/order/put_limit", params)
      
      response = json_response(conn, 200)
      assert response["code"] == 1
      assert response["message"] == "Unsupported market"
    end

    test "returns error for insufficient balance" do
      params = %{
        "market" => "BTCUSDT",
        "side" => "buy",
        "amount" => "1.0",
        "price" => "100000.0"  # Needs 100k but we only have 10k
      }
      
      conn = build_conn()
      conn = post(conn, "/perpetual/v1/order/put_limit", params)
      
      response = json_response(conn, 200)
      assert response["code"] == 1
      assert response["message"] == "Insufficient balance"
    end
  end

  describe "POST /perpetual/v1/order/put_market" do
    setup do
      # Mock current price for market orders
      :meck.new(Coinex.FuturesExchange, [:passthrough])
      :meck.expect(Coinex.FuturesExchange, :fetch_coinex_price, fn -> 
        {:ok, Decimal.new("50000.0")}
      end)
      
      send(Process.whereis(FuturesExchange), :fetch_price)
      :timer.sleep(100)
      
      on_exit(fn -> :meck.unload(Coinex.FuturesExchange) end)
      :ok
    end

    test "successfully creates and fills market order" do
      params = %{
        "market" => "BTCUSDT",
        "side" => "buy",
        "amount" => "0.1",
        "client_id" => "market123"
      }
      
      conn = build_conn()
      conn = post(conn, "/perpetual/v1/order/put_market", params)
      
      response = json_response(conn, 200)
      assert response["code"] == 0
      assert response["message"] == "Ok"
      
      order_data = response["data"]
      assert order_data["market"] == "BTCUSDT"
      assert order_data["side"] == "buy"
      assert order_data["type"] == "market"
      assert order_data["status"] == "filled"
      assert order_data["filled_amount"] == "0.1"
      assert order_data["avg_price"] == "50000.0"
      assert order_data["client_id"] == "market123"
    end
  end

  describe "POST /perpetual/v1/order/cancel" do
    test "successfully cancels pending order" do
      # First create an order
      {:ok, order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.1", "50000.0")
      
      params = %{"order_id" => Integer.to_string(order.id)}
      conn = build_conn()
      conn = post(conn, "/perpetual/v1/order/cancel", params)
      
      response = json_response(conn, 200)
      assert response["code"] == 0
      assert response["message"] == "Ok"
      assert response["data"]["status"] == "cancelled"
    end

    test "returns error for non-existent order" do
      params = %{"order_id" => "999"}
      conn = build_conn()
      conn = post(conn, "/perpetual/v1/order/cancel", params)
      
      response = json_response(conn, 200)
      assert response["code"] == 1
      assert response["message"] == "Order not found"
    end
  end

  describe "GET /perpetual/v1/order/pending" do
    test "returns empty list when no orders" do
      conn = build_conn()
      conn = get(conn, "/perpetual/v1/order/pending")
      
      response = json_response(conn, 200)
      assert response["code"] == 0
      assert response["message"] == "Ok"
      assert response["data"] == []
    end

    test "returns pending orders only" do
      # Create a pending order
      {:ok, order1} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.1", "50000.0")
      
      # Create and cancel another order
      {:ok, order2} = FuturesExchange.submit_limit_order("BTCUSDT", "sell", "0.1", "60000.0")
      {:ok, _cancelled} = FuturesExchange.cancel_order(order2.id)
      
      conn = build_conn()
      conn = get(conn, "/perpetual/v1/order/pending")
      
      response = json_response(conn, 200)
      assert response["code"] == 0
      assert response["message"] == "Ok"
      
      orders = response["data"]
      assert length(orders) == 1
      assert List.first(orders)["order_id"] == order1.id
      assert List.first(orders)["status"] == "pending"
    end
  end

  describe "GET /perpetual/v1/position/pending" do
    setup do
      :meck.new(Coinex.FuturesExchange, [:passthrough])
      :meck.expect(Coinex.FuturesExchange, :fetch_coinex_price, fn -> 
        {:ok, Decimal.new("50000.0")}
      end)
      
      send(Process.whereis(FuturesExchange), :fetch_price)
      :timer.sleep(100)
      
      on_exit(fn -> :meck.unload(Coinex.FuturesExchange) end)
      :ok
    end

    test "returns empty list when no positions" do
      conn = build_conn()
      conn = get(conn, "/perpetual/v1/position/pending")
      
      response = json_response(conn, 200)
      assert response["code"] == 0
      assert response["message"] == "Ok"
      assert response["data"] == []
    end

    test "returns current positions" do
      # Create a position by executing market order
      {:ok, _order} = FuturesExchange.submit_market_order("BTCUSDT", "buy", "0.1")
      
      conn = build_conn()
      conn = get(conn, "/perpetual/v1/position/pending")
      
      response = json_response(conn, 200)
      assert response["code"] == 0
      assert response["message"] == "Ok"
      
      positions = response["data"]
      assert length(positions) == 1
      
      position = List.first(positions)
      assert position["market"] == "BTCUSDT"
      assert position["side"] == "long"
      assert position["amount"] == "0.1"
      assert position["entry_price"] == "50000.0"
    end
  end

  describe "GET /perpetual/v1/asset/query" do
    test "returns initial balance" do
      conn = build_conn()
      conn = get(conn, "/perpetual/v1/asset/query")
      
      response = json_response(conn, 200)
      assert response["code"] == 0
      assert response["message"] == "Ok"
      
      usdt_balance = response["data"]["USDT"]
      assert usdt_balance["available"] == "10000.00"
      assert usdt_balance["frozen"] == "0.00"
      assert usdt_balance["balance_total"] == "10000.00"
      assert usdt_balance["margin"] == "0.00"
      assert usdt_balance["profit_unreal"] == "0.00"
    end

    test "returns updated balance after order" do
      # Create an order to freeze some balance
      {:ok, _order} = FuturesExchange.submit_limit_order("BTCUSDT", "buy", "0.1", "50000.0")
      
      conn = build_conn()
      conn = get(conn, "/perpetual/v1/asset/query")
      
      response = json_response(conn, 200)
      usdt_balance = response["data"]["USDT"]
      
      # Should have frozen 0.1 * 50000 = 5000 USDT
      assert usdt_balance["available"] == "5000.00"
      assert usdt_balance["frozen"] == "5000.00"
      assert usdt_balance["balance_total"] == "10000.00"
    end
  end

  describe "GET /perpetual/v1/market/list" do
    test "returns supported markets" do
      conn = build_conn()
      conn = get(conn, "/perpetual/v1/market/list")
      
      response = json_response(conn, 200)
      assert response["code"] == 0
      assert response["message"] == "Ok"
      
      markets = response["data"]
      assert length(markets) == 1
      
      btc_market = List.first(markets)
      assert btc_market["name"] == "BTCUSDT"
      assert btc_market["stock"] == "BTC"
      assert btc_market["money"] == "USDT"
      assert btc_market["type"] == 1  # Linear contract
    end
  end
end