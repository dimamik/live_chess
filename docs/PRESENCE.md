# Phoenix Presence Integration

## Overview

This app now uses **Phoenix.Presence** for tracking spectators and players in game rooms, replacing the previous MapSet-based approach.

## Benefits

✅ **Automatic Cleanup**: When a LiveView process crashes or user disconnects, Presence automatically removes them  
✅ **Distributed Support**: Works across multiple nodes in a cluster  
✅ **Crash Resilient**: CRDT-based tracking survives process restarts  
✅ **Metadata Support**: Can store user info, join time, role, etc.  
✅ **No Ghost Users**: Automatic heartbeat monitoring prevents stale entries  

## Architecture

### Components

1. **LiveChessWeb.Presence** (`lib/live_chess_web/presence.ex`)
   - Presence tracking module using Phoenix.Presence
   - Configured to use LiveChess.PubSub

2. **Supervision Tree** (`lib/live_chess/application.ex`)
   - Presence started before GameSupervisor
   - Ensures presence tracking is available for all game rooms

3. **LiveView Integration** (`lib/live_chess_web/live/game_live.ex`)
   - Tracks user presence on mount
   - Subscribes to presence_diff events
   - Updates spectator count reactively

### Data Flow

```
User Connects → LiveView.mount()
              ↓
   Presence.track(self(), topic, token, metadata)
              ↓
   Subscribe to "game:#{room_id}" for presence_diff
              ↓
   Count spectators from Presence.list(topic)
              ↓
   Update UI with spectator count
              ↓
User Disconnects → Presence auto-removes entry
              ↓
   Broadcast presence_diff to all subscribers
              ↓
   All LiveViews update spectator count
```

## Implementation Details

### Tracking on Mount

```elixir
# When user connects to a game room
topic = "game:#{room_id}"
{:ok, _} = Presence.track(self(), topic, player_token, %{
  role: :spectator,  # or :white, :black
  joined_at: System.system_time(:second),
  online_at: inspect(System.system_time(:second))
})
```

### Counting Spectators

```elixir
# Count only spectators (not players)
presences = Presence.list("game:#{room_id}")

spectator_count =
  presences
  |> Enum.filter(fn {_id, %{metas: metas}} ->
    Enum.any?(metas, fn meta -> Map.get(meta, :role) == :spectator end)
  end)
  |> Enum.count()
```

### Handling Updates

```elixir
# Automatically called when presence changes
def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
  topic = "game:#{socket.assigns.room_id}"
  {:noreply, update_spectator_count_from_presence(socket, topic)}
end
```

## Backward Compatibility

The GameServer still maintains the `spectators` MapSet field for backward compatibility during migration, but it's no longer the source of truth. Presence is now authoritative.

## Testing

To verify Presence is working:

1. Open a game room in multiple browser tabs
2. Check the spectator count updates in real-time
3. Close tabs and verify count decreases
4. Kill the GameServer process and watch it restart - spectators remain tracked

## Future Enhancements

- Show spectator names/avatars using metadata
- Track player online/offline status
- Show "X is typing..." for chat features
- Display reconnection status
- Analytics on viewing duration (using `joined_at` timestamp)
