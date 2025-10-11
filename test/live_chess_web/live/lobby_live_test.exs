defmodule LiveChessWeb.LobbyLiveTest do
  use LiveChessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders lobby page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "h1", "Live Chess")
    assert has_element?(view, "button", "Create Room")
    assert has_element?(view, "form[phx-submit=\"join_room\"]")
  end
end
