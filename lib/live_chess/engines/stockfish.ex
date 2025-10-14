defmodule LiveChess.Engines.Stockfish do
  @moduledoc """
  HTTP client for Stockfish-powered analysis. Uses the Lichess Cloud Evaluation
  API by default and can be configured via `config :live_chess, #{inspect(__MODULE__)}`.
  """

  @behaviour LiveChess.Engines.Engine
  require Logger

  @type move :: %{
          from: String.t(),
          to: String.t(),
          promotion: String.t(),
          promotion_piece: String.t() | nil,
          uci: String.t()
        }

  @type pv_line :: %{
          moves: [String.t()],
          cp: integer() | nil,
          normalized_cp: integer() | nil,
          mate: integer() | nil,
          normalized_mate: integer() | nil,
          depth: integer() | nil,
          multipv: integer() | nil
        }

  @type evaluation :: %{
          fen: String.t(),
          score_cp: integer(),
          normalized_cp: integer(),
          mate: integer() | nil,
          normalized_mate: integer() | nil,
          depth: integer() | nil,
          knodes: integer() | nil,
          best_move: move(),
          lines: [pv_line()],
          raw: map()
        }

  @spec source() :: atom()
  def source, do: :stockfish

  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(config(), :enabled?, true)
  end

  @spec evaluate(String.t(), keyword()) :: {:ok, evaluation()} | {:error, term()}
  def evaluate(fen, opts \\ [])

  def evaluate(fen, opts) when is_binary(fen) do
    fen = String.trim(fen || "")

    cond do
      fen == "" -> {:error, :invalid_fen}
      not enabled?() -> {:error, :disabled}
      true -> do_evaluate(fen, opts)
    end
  end

  def evaluate(_fen, _opts), do: {:error, :invalid_fen}

  @spec best_move(String.t(), keyword()) :: {:ok, move()} | {:error, term()}
  def best_move(fen, opts \\ []) do
    with {:ok, %{best_move: move}} <- evaluate(fen, opts) do
      {:ok, move}
    end
  end

  defp do_evaluate(fen, opts) do
    params = build_params(fen, opts)
    headers = build_headers()

    request_opts = [
      url: base_url(),
      params: params,
      headers: headers,
      receive_timeout: Keyword.get(opts, :timeout, timeout())
    ]

    request_opts =
      case Keyword.get(opts, :retry, retry()) do
        nil -> request_opts
        retry_option -> Keyword.put(request_opts, :retry, retry_option)
      end

    case Req.get(request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_response(fen, body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning(fn ->
          "Stockfish API returned status #{status}: #{inspect(body)}"
        end)

        {:error, {:http_error, status}}

      {:error, %Req.TransportError{} = error} ->
        Logger.warning(fn -> "Stockfish API transport error: #{Exception.message(error)}" end)
        {:error, {:transport_error, error.reason}}

      {:error, error} ->
        Logger.warning(fn -> "Stockfish API request failed: #{inspect(error)}" end)
        {:error, error}
    end
  end

  defp parse_response(_fen, body) when not is_map(body) do
    {:error, :invalid_response}
  end

  defp parse_response(fen, %{"pvs" => pvs} = body) when is_list(pvs) and pvs != [] do
    with {:ok, uci_move} <- best_uci(body),
         {:ok, move} <- parse_uci_move(uci_move),
         orientation <- orientation_sign(fen) do
      primary_line = List.first(pvs)
      raw_cp = normalize_number(primary_line["cp"])
      raw_mate = normalize_number(primary_line["mate"])

      normalized_cp = normalize_score(raw_cp, orientation)
      normalized_mate = normalize_score(raw_mate, orientation)

      lines = Enum.map(pvs, &parse_line(&1, orientation))

      evaluation = %{
        fen: fen,
        score_cp: normalized_cp || 0,
        normalized_cp: normalized_cp,
        mate: raw_mate,
        normalized_mate: normalized_mate,
        depth: normalize_number(body["depth"] || primary_line["depth"]),
        knodes: normalize_number(body["knodes"]),
        best_move: Map.put(move, :uci, uci_move),
        lines: lines,
        raw: body,
        source: :stockfish,
        engine_name: "Stockfish Cloud Eval"
      }

      {:ok, evaluation}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_response(_fen, _body), do: {:error, :analysis_unavailable}

  defp parse_line(line, orientation) when is_map(line) do
    moves =
      line
      |> Map.get("moves", "")
      |> to_string()
      |> String.split(" ", trim: true)

    raw_cp = normalize_number(Map.get(line, "cp"))
    raw_mate = normalize_number(Map.get(line, "mate"))

    %{
      moves: moves,
      cp: raw_cp,
      normalized_cp: normalize_score(raw_cp, orientation),
      mate: raw_mate,
      normalized_mate: normalize_score(raw_mate, orientation),
      depth: normalize_number(Map.get(line, "depth")),
      multipv: normalize_number(Map.get(line, "multipv"))
    }
  end

  defp parse_line(_line, _orientation),
    do: %{
      moves: [],
      cp: nil,
      normalized_cp: nil,
      mate: nil,
      normalized_mate: nil,
      depth: nil,
      multipv: nil
    }

  defp best_uci(%{"best" => move}) when is_binary(move) and byte_size(move) >= 4 do
    {:ok, move}
  end

  defp best_uci(%{"pvs" => [primary | _]}) do
    case primary do
      %{"moves" => moves} when is_binary(moves) ->
        case String.split(moves, " ", trim: true) do
          [move | _] when byte_size(move) >= 4 -> {:ok, move}
          _ -> {:error, :no_best_move}
        end

      _ ->
        {:error, :no_best_move}
    end
  end

  defp best_uci(_), do: {:error, :no_best_move}

  defp parse_uci_move(<<from::binary-size(2), to::binary-size(2), promo::binary-size(1)>> = uci) do
    {:ok,
     %{
       from: String.downcase(from),
       to: String.downcase(to),
       promotion: String.downcase(promo),
       promotion_piece: String.downcase(promo),
       uci: uci
     }}
  end

  defp parse_uci_move(<<from::binary-size(2), to::binary-size(2)>> = uci) do
    {:ok,
     %{
       from: String.downcase(from),
       to: String.downcase(to),
       promotion: "q",
       promotion_piece: nil,
       uci: uci
     }}
  end

  defp parse_uci_move(_), do: {:error, :invalid_move}

  defp orientation_sign(fen) do
    case String.split(fen, " ", parts: 3) do
      [_board, "w" | _] -> 1
      [_board, "b" | _] -> -1
      _ -> 1
    end
  end

  defp normalize_score(nil, _orientation), do: nil
  defp normalize_score(value, orientation) when is_integer(value), do: value * orientation
  defp normalize_score(value, orientation) when is_float(value), do: round(value * orientation)

  defp normalize_score(value, orientation) when is_binary(value) do
    value
    |> normalize_number()
    |> normalize_score(orientation)
  end

  defp normalize_score(_value, _orientation), do: nil

  defp normalize_number(nil), do: nil
  defp normalize_number(value) when is_integer(value), do: value
  defp normalize_number(value) when is_float(value), do: round(value)

  defp normalize_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} ->
        int

      :error ->
        case Float.parse(value) do
          {float, _} -> round(float)
          :error -> nil
        end
    end
  end

  defp normalize_number(value) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp build_params(fen, opts) do
    multi_pv = Keyword.get(opts, :multi_pv, multi_pv())

    base_params =
      [
        {"fen", fen},
        {"multiPv", multi_pv}
      ]

    extra_params = Keyword.get(config(), :extra_params, [])

    base_params ++ extra_params
  end

  defp build_headers do
    headers = [{"accept", "application/json"}]

    case api_token() do
      nil -> headers
      token -> headers ++ [{"authorization", "Bearer #{token}"}]
    end
  end

  defp base_url do
    Keyword.get(config(), :base_url, "https://lichess.org/api/cloud-eval")
  end

  defp multi_pv do
    Keyword.get(config(), :multi_pv, 3)
  end

  defp timeout do
    Keyword.get(config(), :request_timeout, 8_000)
  end

  defp retry do
    Keyword.get(config(), :retry, :safe_transient)
  end

  defp api_token do
    Keyword.get(config(), :api_token)
  end

  defp config do
    Application.get_env(:live_chess, __MODULE__, [])
  end
end
