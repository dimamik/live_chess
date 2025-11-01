defmodule LiveChessWeb.EndgameParticles do
  @moduledoc """
  Helper functions to generate endgame particles (confetti and tears).

  This module programmatically produces particle attribute maps that are
  converted into inline CSS variables by the LiveView renderer. Keeping
  this logic in a separate module makes it easier to test and tune.
  """

  @doc "Return a list of confetti particle maps (class + style)."
  def celebration_particles(opts \\ []) do
    colors =
      opts[:colors] ||
        [
          "#facc15",
          "#f97316",
          "#f472b6",
          "#38bdf8",
          "#34d399",
          "#a855f7",
          "#22d3ee",
          "#ef4444",
          "#14b8a6",
          "#f87171",
          "#60a5fa",
          "#c084fc",
          "#fde047",
          "#fb7185",
          "#fca5a5",
          "#10b981",
          "#8b5cf6",
          "#06b6d4",
          "#f59e0b",
          "#ec4899"
        ]

    count = opts[:confetti_count] || 200

    1..count
    |> Enum.map(fn i ->
      left_val = rem(i * 11, 140) - 20
      left = "#{left_val}%"
      delay = "#{Float.round((i - 1) * 0.015, 3)}s"
      duration = "#{Float.round(2.8 + rem(i, 10) * 0.35, 2)}s"
      color = Enum.at(colors, rem(i - 1, length(colors)))
      size = "#{Float.round(0.55 + rem(i, 6) * 0.2, 2)}rem"

      confetti_particle(%{left: left, delay: delay, duration: duration, color: color, size: size})
    end)
  end

  @doc "Return a list of tear particle maps (class + style)."
  def defeat_particles(opts \\ []) do
    count = opts[:tear_count] || 280

    1..count
    |> Enum.map(fn i ->
      left_val = rem(i * 6, 140) - 20
      left = "#{left_val}%"
      delay = "#{Float.round((i - 1) * 0.012, 3)}s"
      duration = "#{Float.round(2.0 + rem(i, 7) * 0.25, 2)}s"
      size = "#{Float.round(0.4 + rem(i, 5) * 0.14, 2)}rem"

      tear_particle(%{left: left, delay: delay, duration: duration, size: size})
    end)
  end

  defp confetti_particle(attrs) do
    style =
      Enum.map_join(attrs, "; ", fn
        {:left, value} -> "--confetti-left: #{value}"
        {:delay, value} -> "--confetti-delay: #{value}"
        {:duration, value} -> "--confetti-duration: #{value}"
        {:size, value} -> "--confetti-size: #{value}"
        {:color, value} -> "--confetti-color: #{value}"
      end)

    %{class: "endgame-confetti", style: style <> ";"}
  end

  defp tear_particle(attrs) do
    style =
      Enum.map_join(attrs, "; ", fn
        {:left, value} -> "--tear-left: #{value}"
        {:delay, value} -> "--tear-delay: #{value}"
        {:duration, value} -> "--tear-duration: #{value}"
        {:size, value} -> "--tear-size: #{value}"
      end)

    %{class: "endgame-tear", style: style <> ";"}
  end
end
