import Config

# Configure your database for tests
config :live_chess, LiveChess.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "live_chess_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :live_chess, enable_game_restorer: false
config :live_chess, LiveChess.Engines.Stockfish, enabled?: false
config :live_chess, LiveChess.Engines.ChessApi, enabled?: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :live_chess, LiveChessWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "P6x42kyQa2nNiw0UgPE/Q+NFUmBFCWT/FuyrXtq2F9CjkrMjhGIAXYYWgVRtH7VB",
  server: false

# In test we don't send emails
config :live_chess, LiveChess.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
