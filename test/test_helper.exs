ExUnit.start()
# Ecto.Adapters.SQL.Sandbox.mode(Coinex.Repo, :manual)  # Commented out - app doesn't use DB

# Start Phoenix endpoint for LiveView tests
{:ok, _} = Application.ensure_all_started(:coinex)
