ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Coinex.Repo, :manual)

# Start Phoenix endpoint for LiveView tests
Application.ensure_all_started(:coinex)
