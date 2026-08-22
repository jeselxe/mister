defmodule Mister.Repo do
  use Ecto.Repo,
    otp_app: :mister,
    adapter: Ecto.Adapters.Postgres
end
