defmodule LiveChessWeb.Presence do
  @moduledoc """
  Provides presence tracking for game rooms.
  
  Tracks players and spectators across the application, with automatic
  cleanup when processes terminate. Works across distributed nodes.
  """
  use Phoenix.Presence,
    otp_app: :live_chess,
    pubsub_server: LiveChess.PubSub
end
