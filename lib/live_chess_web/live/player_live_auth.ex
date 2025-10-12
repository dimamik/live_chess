defmodule LiveChessWeb.PlayerLiveAuth do
  @moduledoc false

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Phoenix.LiveView.Socket

  def on_mount(:default, _params, _session, %Socket{} = socket) do
    token =
      if LiveView.connected?(socket) do
        socket
        |> LiveView.get_connect_params()
        |> case do
          %{"player_token" => tab_token} when is_binary(tab_token) and tab_token != "" ->
            tab_token

          _ ->
            LiveChess.Games.generate_player_token()
        end
      else
        nil
      end

    {:cont, Component.assign(socket, :player_token, token)}
  end
end
