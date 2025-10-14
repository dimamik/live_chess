defmodule LiveChess.Engines.ChessApi do
  @moduledoc """
  HTTP client for https://chess-api.com/ providing Stockfish 17 powered
  evaluations and best-move suggestions.
  """

  @behaviour LiveChess.Engines.Engine

  require Logger

  @impl true
  def source, do: :chess_api

  @impl true
  def enabled? do
    Keyword.get(config(), :enabled?, true)
  end

  @impl true
  def evaluate(fen, opts \\ [])

  def evaluate(fen, opts) when is_binary(fen) do
    fen = String.trim(fen || "")

    cond do
      fen == "" -> {:error, :invalid_fen}
      not enabled?() -> {:error, :disabled}
      true -> do_request(fen, opts)
    end
  end

  def evaluate(_fen, _opts), do: {:error, :invalid_fen}

  @impl true
  def best_move(fen, opts \\ []) do
    case evaluate(fen, opts) do
      {:ok, %{best_move: %{from: _from, to: _to} = move}} -> {:ok, move}
      {:ok, _evaluation} -> {:error, :no_move}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_request(fen, opts) do
    body = build_body(fen, opts)

    request_opts = [
      url: base_url(),
      json: body,
      receive_timeout: Keyword.get(opts, :timeout, timeout()),
      retry: Keyword.get(opts, :retry, retry())
    ]

    case Req.post(request_opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        parse_response(fen, body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning(fn ->
          "Chess API returned status #{status}: #{inspect(body)}"
        end)

        {:error, {:http_error, status}}

      {:error, %Req.TransportError{} = error} ->
        Logger.warning(fn -> "Chess API transport error: #{Exception.message(error)}" end)
        {:error, {:transport_error, error.reason}}

      {:error, error} ->
        Logger.warning(fn -> "Chess API request failed: #{inspect(error)}" end)
        {:error, error}
    end
  end

  defp parse_response(fen, %{"move" => move} = body) when is_binary(move) do
    with {:ok, best_move} <- parse_uci_move(move) do
      cp = parse_centipawns(body)
      mate = parse_mate(body)
      depth = normalize_number(Map.get(body, "depth"))
      lines = build_lines(body, cp, mate, depth)

      evaluation = %{
        fen: fen,
        score_cp: cp || 0,
        normalized_cp: cp,
        mate: mate,
        normalized_mate: mate,
        depth: depth,
        knodes: nil,
        best_move:
          best_move
          |> Map.put(:uci, move)
          |> Map.put(:engine, :chess_api),
        lines: lines,
        raw: body,
        source: :chess_api,
        engine_name: "Chess API",
        win_chance: parse_win_chance(body)
      }

      {:ok, evaluation}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_response(_fen, body) do
    Logger.warning(fn -> "Unexpected Chess API response: #{inspect(body)}" end)
    {:error, :invalid_response}
  end

  defp build_body(fen, opts) do
    %{}
    |> Map.put("fen", fen)
    |> maybe_put("variants", Keyword.get(opts, :variants, variants()))
    |> maybe_put("depth", Keyword.get(opts, :depth, depth()))
    |> maybe_put("maxThinkingTime", Keyword.get(opts, :max_thinking_time, max_thinking_time()))
    |> maybe_put("searchmoves", Keyword.get(opts, :searchmoves))
    |> maybe_put("taskId", Keyword.get(opts, :task_id))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, :undefined), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_lines(body, cp, mate, depth) do
    moves =
      body
      |> Map.get("continuationArr", [])
      |> Enum.map(&to_string/1)

    if moves == [] do
      []
    else
      [
        %{
          moves: moves,
          cp: cp,
          normalized_cp: cp,
          mate: mate,
          normalized_mate: mate,
          depth: depth,
          multipv: 1
        }
      ]
    end
  end

  defp parse_centipawns(%{"centipawns" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_centipawns(%{"centipawns" => value}) when is_number(value) do
    round(value)
  end

  defp parse_centipawns(%{"eval" => value}) when is_number(value) do
    value
    |> Kernel.*(100)
    |> Float.round()
    |> trunc()
  end

  defp parse_centipawns(_), do: nil

  defp parse_mate(%{"mate" => value}) when is_integer(value), do: value
  defp parse_mate(%{"mate" => value}) when is_float(value), do: round(value)
  defp parse_mate(_), do: nil

  defp parse_win_chance(%{"winChance" => value}) when is_float(value) do
    Float.round(value, 4)
  end

  defp parse_win_chance(_), do: nil

  defp parse_uci_move(move) when is_binary(move) do
    normalized = String.downcase(move)

    case normalized do
      <<from_file, from_rank, to_file, to_rank, promo::binary-size(1)>> ->
        if valid_square?(from_file, from_rank) and valid_square?(to_file, to_rank) do
          promotion = String.downcase(promo)

          {:ok,
           %{
             from: <<from_file, from_rank>>,
             to: <<to_file, to_rank>>,
             promotion: promotion,
             promotion_piece: promotion
           }}
        else
          {:error, :invalid_move}
        end

      <<from_file, from_rank, to_file, to_rank>> ->
        if valid_square?(from_file, from_rank) and valid_square?(to_file, to_rank) do
          {:ok,
           %{
             from: <<from_file, from_rank>>,
             to: <<to_file, to_rank>>,
             promotion: "q",
             promotion_piece: nil
           }}
        else
          {:error, :invalid_move}
        end

      _ ->
        {:error, :invalid_move}
    end
  end

  defp parse_uci_move(_), do: {:error, :invalid_move}

  defp valid_square?(file, rank) when file >= ?a and file <= ?h and rank >= ?1 and rank <= ?8,
    do: true

  defp valid_square?(_file, _rank), do: false

  defp normalize_number(nil), do: nil
  defp normalize_number(value) when is_integer(value), do: value
  defp normalize_number(value) when is_float(value), do: round(value)

  defp normalize_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp max_thinking_time do
    Keyword.get(config(), :max_thinking_time, 50)
  end

  defp depth do
    Keyword.get(config(), :depth, 12)
  end

  defp variants do
    Keyword.get(config(), :variants, 1)
  end

  defp timeout do
    Keyword.get(config(), :request_timeout, 8_000)
  end

  defp retry do
    Keyword.get(config(), :retry, :safe_transient)
  end

  defp base_url do
    Keyword.get(config(), :base_url, "https://chess-api.com/v1")
  end

  defp config do
    Application.get_env(:live_chess, __MODULE__, [])
  end
end
