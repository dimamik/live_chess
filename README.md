# live_chess

Multiplayer chess built with Phoenix LiveView. Players can spin up an ad-hoc room, share a join link, and play a real-time match powered by in-memory processes—no database required.

## Features

- In-memory game supervisor that dynamically spins up a `GenServer` per room
- Live lobby for creating rooms, joining by code, and sharing invite links
- Real-time board updates, move validation, and basic move history powered by the `chess` Hex package
- Automatic session token issuance so visitors can reconnect to their seat without accounts
- Remote engine-backed evaluation and robot moves via https://chess-api.com/, with Stockfish Cloud Eval support available via configuration and heuristics as a fallback
- **Phoenix.Presence** integration for accurate, crash-resilient spectator tracking across distributed nodes

## Getting started

1. Install dependencies and front-end tooling:
   - `mix setup`
2. Launch the Phoenix server:
   - `mix phx.server`
3. Visit [`http://localhost:4000`](http://localhost:4000) to open the lobby.

## Playing a match

1. Click **Create Room** to start a match. A shareable link and room code appear on the game page.
2. When the second player joins using the link or code, the game immediately begins.
3. Moves are validated on the server via the `chess` library, with results broadcast to both clients.

## Development notes

- All game state lives in memory. `LiveChess.GameSupervisor` and `LiveChess.GameServer` coordinate lifecycle and move validation.
- Game topics are broadcast over `Phoenix.PubSub`, allowing LiveViews to stay synced without manual polling.
- **Phoenix.Presence** tracks spectators and players with automatic cleanup when connections drop. See [docs/PRESENCE.md](docs/PRESENCE.md) for details.
- The UI uses TailwindCSS utility classes that ship with new Phoenix projects—no external CSS framework required.

## Engine configuration

The application uses a pluggable engine behaviour (`LiveChess.Engines.Engine`). By default, it talks to [chess-api.com](https://chess-api.com/) for Stockfish 17 evaluations. The legacy Lichess Cloud Eval client is still available and can be re-enabled if preferred.

| Variable                | Purpose                                                           | Default                    |
| ----------------------- | ----------------------------------------------------------------- | -------------------------- |
| `CHESS_API_URL`         | Override the chess-api.com endpoint                               | `https://chess-api.com/v1` |
| `CHESS_API_VARIANTS`    | Number of principal variations (1-5)                              | `1`                        |
| `CHESS_API_DEPTH`       | Search depth (1+)                                                 | `12`                       |
| `CHESS_API_THINKING_MS` | Thinking time budget per request                                  | `50`                       |
| `CHESS_API_TIMEOUT_MS`  | HTTP request timeout                                              | `8000`                     |
| `CHESS_API_ENABLED`     | Disable the remote engine when set to `false`/`0`                 | `true`                     |
| `STOCKFISH_*`           | Existing Stockfish Cloud Eval overrides (see `config/config.exs`) | _optional_                 |

Switch `config :live_chess, :engine` to `LiveChess.Engines.Stockfish` if you want to revert to the Lichess client. When the engine is disabled or unavailable, the server falls back to the built-in heuristic evaluator and a simple random-move robot so that gameplay can continue offline.

## Next steps

- Add persistence for finished games and matchmaking history using a database
- Expand the ruleset to include timers, custom variants, and resign/draw workflows
- Enhance the UI with richer piece rendering (SVG sprites) and move notation formatting

## Useful Phoenix resources

- Official website: https://www.phoenixframework.org/
- Guides: https://hexdocs.pm/phoenix/overview.html
- Docs: https://hexdocs.pm/phoenix
- Forum: https://elixirforum.com/c/phoenix-forum
- Source: https://github.com/phoenixframework/phoenix
