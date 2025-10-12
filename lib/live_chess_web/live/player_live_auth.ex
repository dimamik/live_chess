defmodule LiveChessWeb.PlayerLiveAuth do
  @moduledoc false

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Phoenix.LiveView.Socket

  def on_mount(:default, _params, session, %Socket{} = socket) do
    base_token = session["player_token"] || LiveChess.Games.generate_player_token()

    active_token =
      if LiveView.connected?(socket) do
        socket
        |> LiveView.get_connect_params()
        |> case do
          %{"player_token" => tab_token} when is_binary(tab_token) and tab_token != "" ->
            tab_token

          _ ->
            base_token
        end
      else
        base_token
      end

    {:cont, Component.assign(socket, :player_token, active_token)}
  end
end
