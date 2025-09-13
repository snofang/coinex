defmodule Coinex.Repo do
  use Ecto.Repo,
    otp_app: :coinex,
    adapter: Ecto.Adapters.Postgres
end
