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
          "#fca5a5"
        ]

    count = opts[:confetti_count] || 160

    1..count
    |> Enum.map(fn i ->
      left_val = rem(i * 11, 140) - 20
      left = "#{left_val}%"
      delay = "#{Float.round((i - 1) * 0.02, 2)}s"
      duration = "#{Float.round(3.0 + rem(i, 8) * 0.28, 2)}s"
      color = Enum.at(colors, rem(i - 1, length(colors)))
      size = "#{Float.round(0.6 + rem(i, 5) * 0.18, 2)}rem"

      confetti_particle(%{left: left, delay: delay, duration: duration, color: color, size: size})
    end)
  end

  @doc "Return a list of tear particle maps (class + style)."
  def defeat_particles(opts \\ []) do
    count = opts[:tear_count] || 220

    1..count
    |> Enum.map(fn i ->
      left_val = rem(i * 6, 140) - 20
      left = "#{left_val}%"
      delay = "#{Float.round((i - 1) * 0.015, 3)}s"
      duration = "#{Float.round(2.2 + rem(i, 6) * 0.2, 2)}s"
      size = "#{Float.round(0.45 + rem(i, 4) * 0.12, 2)}rem"

      tear_particle(%{left: left, delay: delay, duration: duration, size: size})
    end)
  end

  defp confetti_particle(attrs) do
    style =
      attrs
      |> Enum.map(fn
        {:left, value} -> "--confetti-left: #{value}"
        {:delay, value} -> "--confetti-delay: #{value}"
        {:duration, value} -> "--confetti-duration: #{value}"
        {:size, value} -> "--confetti-size: #{value}"
        {:color, value} -> "--confetti-color: #{value}"
      end)
      |> Enum.join("; ")

    %{class: "endgame-confetti", style: style <> ";"}
  end

  defp tear_particle(attrs) do
    style =
      attrs
      |> Enum.map(fn
        {:left, value} -> "--tear-left: #{value}"
        {:delay, value} -> "--tear-delay: #{value}"
        {:duration, value} -> "--tear-duration: #{value}"
        {:size, value} -> "--tear-size: #{value}"
      end)
      |> Enum.join("; ")

    %{class: "endgame-tear", style: style <> ";"}
  end
end
