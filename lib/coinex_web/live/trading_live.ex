defmodule CoinexWeb.TradingLive do
  use CoinexWeb, :live_view

  alias Coinex.FuturesExchange

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Update every 2 seconds
      Process.send_after(self(), :update_data, 2000)
    end

    socket = 
      socket
      |> assign(:current_price, nil)
      |> assign(:balance, nil)
      |> assign(:orders, [])
      |> assign(:positions, [])
      |> assign(:order_form, to_form(%{}))
      |> assign(:order_side, "buy")
      |> assign(:order_type, "limit")
      |> assign(:order_amount, "")
      |> assign(:order_price, "")
      # Orders filtering and pagination
      |> assign(:orders_status_filter, "all")
      |> assign(:orders_page, 1)
      |> assign(:orders_per_page, 10)
      |> assign(:orders_total_count, 0)
      |> assign(:orders_filtered, [])
      |> update_all_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:update_data, socket) do
    # Schedule next update
    Process.send_after(self(), :update_data, 2000)
    
    socket = update_all_data(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("place_order", %{"order" => order_params}, socket) do
    %{
      "side" => side,
      "type" => type,
      "amount" => amount,
      "price" => price
    } = order_params

    result = case type do
      "market" ->
        FuturesExchange.submit_market_order("BTCUSDT", side, amount, "ui_order")
      "limit" ->
        FuturesExchange.submit_limit_order("BTCUSDT", side, amount, price, "ui_order")
    end

    socket = case result do
      {:ok, _order} ->
        socket
        |> put_flash(:info, "Order placed successfully!")
        |> assign(:order_amount, "")
        |> assign(:order_price, "")
        |> update_all_data()
      
      {:error, reason} ->
        put_flash(socket, :error, "Order failed: #{reason}")
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_order", %{"order_id" => order_id}, socket) do
    case FuturesExchange.cancel_order(String.to_integer(order_id)) do
      {:ok, _cancelled_order} ->
        socket = 
          socket
          |> put_flash(:info, "Order cancelled successfully!")
          |> update_all_data()
        {:noreply, socket}
      
      {:error, reason} ->
        socket = put_flash(socket, :error, "Cancel failed: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_form", %{"order" => order_params}, socket) do
    socket = 
      socket
      |> assign(:order_side, Map.get(order_params, "side", "buy"))
      |> assign(:order_type, Map.get(order_params, "type", "limit"))
      |> assign(:order_amount, Map.get(order_params, "amount", ""))
      |> assign(:order_price, Map.get(order_params, "price", ""))

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_test_price", %{"price" => price}, socket) do
    case Decimal.new(price) do
      %Decimal{} = decimal_price ->
        FuturesExchange.set_current_price(decimal_price)
        socket = 
          socket
          |> put_flash(:info, "Price set to $#{price} for testing")
          |> update_all_data()
        {:noreply, socket}
      
      _ ->
        socket = put_flash(socket, :error, "Invalid price format")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_orders", %{"status" => status}, socket) do
    socket = 
      socket
      |> assign(:orders_status_filter, status)
      |> assign(:orders_page, 1)  # Reset to first page when filtering
      |> update_orders_display()

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page_num = String.to_integer(page)
    socket = 
      socket
      |> assign(:orders_page, page_num)
      |> update_orders_display()

    {:noreply, socket}
  end

  defp update_all_data(socket) do
    current_price = FuturesExchange.get_current_price()
    balance = FuturesExchange.get_balance()
    orders = FuturesExchange.get_orders()
    positions = FuturesExchange.get_positions()

    socket
    |> assign(:current_price, current_price)
    |> assign(:balance, balance)
    |> assign(:orders, orders)
    |> assign(:positions, positions)
    |> update_orders_display()
  end

  defp update_orders_display(socket) do
    all_orders = socket.assigns.orders
    status_filter = socket.assigns.orders_status_filter
    page = socket.assigns.orders_page
    per_page = socket.assigns.orders_per_page

    # Sort orders descending by creation time (newest first)
    sorted_orders = Enum.sort(all_orders, fn order1, order2 ->
      DateTime.compare(order1.created_at, order2.created_at) != :lt
    end)

    # Filter by status
    filtered_orders = case status_filter do
      "all" -> sorted_orders
      status -> Enum.filter(sorted_orders, fn order -> order.status == status end)
    end

    total_count = length(filtered_orders)

    # Paginate
    start_index = (page - 1) * per_page
    
    paginated_orders = filtered_orders |> Enum.slice(start_index, per_page)

    socket
    |> assign(:orders_filtered, paginated_orders)
    |> assign(:orders_total_count, total_count)
  end

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(decimal), do: Decimal.to_string(decimal, :normal)

  defp format_price(nil), do: "N/A"
  defp format_price(decimal), do: "$#{Decimal.to_string(decimal, :normal)}"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp order_status_class("pending"), do: "bg-yellow-100 text-yellow-800"
  defp order_status_class("filled"), do: "bg-green-100 text-green-800"
  defp order_status_class("cancelled"), do: "bg-red-100 text-red-800"
  defp order_status_class(_), do: "bg-gray-100 text-gray-800"

  defp position_side_class("long"), do: "text-green-600 font-semibold"
  defp position_side_class("short"), do: "text-red-600 font-semibold"

  defp pnl_class(pnl) do
    case Decimal.compare(pnl, Decimal.new("0")) do
      :gt -> "text-green-600 font-semibold"
      :lt -> "text-red-600 font-semibold"
      :eq -> "text-gray-600"
    end
  end

  defp total_pages(total_count, per_page) do
    (total_count / per_page) |> ceil()
  end

  defp page_numbers(current_page, total_pages) do
    start_page = max(1, current_page - 2)
    end_page = min(total_pages, current_page + 2)
    Enum.to_list(start_page..end_page)
  end

  defp status_filter_class(current_filter, filter_value) do
    if current_filter == filter_value do
      "bg-blue-500 text-white"
    else
      "bg-gray-200 text-gray-700 hover:bg-gray-300"
    end
  end
end