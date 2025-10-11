defmodule LiveChessWeb.PlayerLiveAuth do
  @moduledoc false

  alias Phoenix.Component
  alias Phoenix.LiveView.Socket

  def on_mount(:default, _params, session, %Socket{} = socket) do
    token = session["player_token"] || LiveChess.Games.generate_player_token()
    {:cont, Component.assign(socket, :player_token, token)}
  end
end
