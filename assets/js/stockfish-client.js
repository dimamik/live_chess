/**
 * Client-side Stockfish WebAssembly engine for position evaluation
 */

let stockfishWorker = null;
let isEngineReady = false;
let pendingEvaluations = new Map();
let evaluationCounter = 0;

// Initialize Stockfish engine
export async function initStockfish(workerPath) {
  if (stockfishWorker) return stockfishWorker;

  return new Promise((resolve, reject) => {
    try {
      // Use the provided path from Phoenix (resolved correctly in both dev and prod)
      stockfishWorker = new Worker(workerPath);

      // Set up message handler
      stockfishWorker.onmessage = (event) => {
        handleEngineMessage(event.data);
      };

      stockfishWorker.onerror = (error) => {
        console.error("Stockfish worker error:", error);
        reject(error);
      };

      // Initialize engine
      stockfishWorker.postMessage("uci");

      setTimeout(() => {
        isEngineReady = true;
        console.log("Stockfish engine ready (lite single-threaded)");
        resolve(stockfishWorker);
      }, 500);
    } catch (err) {
      console.error("Failed to initialize Stockfish:", err);
      reject(err);
    }
  });
}

function handleEngineMessage(message) {
  // Parse engine output
  if (message.includes("info") && message.includes("score")) {
    // Extract evaluation from UCI info line
    const match = message.match(/score (cp|mate) (-?\d+)/);
    if (match) {
      const [_, type, value] = match;
      const score = {
        type: type, // 'cp' for centipawns, 'mate' for mate
        value: parseInt(value, 10),
      };

      // Find pending evaluation and resolve it
      for (const [id, pending] of pendingEvaluations.entries()) {
        if (message.includes(`multipv ${pending.multipv || 1}`)) {
          pending.score = score;
        }
      }
    }
  } else if (message.includes("bestmove")) {
    // Extract best move from "bestmove e2e4 ponder ..."
    const bestmoveMatch = message.match(
      /bestmove\s+([a-h][1-8][a-h][1-8][qrbn]?)/
    );
    const bestMove = bestmoveMatch ? bestmoveMatch[1] : null;

    // Evaluation complete
    const currentId = Array.from(pendingEvaluations.keys())[0];
    if (currentId !== undefined) {
      const pending = pendingEvaluations.get(currentId);
      if (pending && pending.resolve) {
        const result = pending.score || { type: "cp", value: 0 };
        result.bestMove = bestMove;
        pending.resolve(result);
        pendingEvaluations.delete(currentId);
      }
    }
  }
}

/**
 * Evaluate a position given in FEN notation
 * @param {string} fen - Position in FEN notation
 * @param {object} options - Evaluation options (depth, time)
 * @returns {Promise<object>} Evaluation result with score_cp, advantage, etc.
 */
export async function evaluatePosition(fen, options = {}) {
  if (!stockfishWorker || !isEngineReady) {
    await initStockfish();
  }

  const depth = options.depth || 12;
  const evalId = evaluationCounter++;

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingEvaluations.delete(evalId);
      reject(new Error("Evaluation timeout"));
    }, options.timeout || 5000);

    pendingEvaluations.set(evalId, {
      resolve: (score) => {
        clearTimeout(timeout);
        resolve(convertToEvaluation(fen, score));
      },
      reject,
      multipv: 1,
      score: null,
    });

    // Send position and evaluation command
    stockfishWorker.postMessage("position fen " + fen);
    stockfishWorker.postMessage(`go depth ${depth}`);
  });
}

/**
 * Convert Stockfish score to evaluation format expected by the app
 */
function convertToEvaluation(fen, score) {
  const scoreCp =
    score.type === "mate" ? (score.value > 0 ? 10000 : -10000) : score.value;

  const advantage = scoreCp > 40 ? "white" : scoreCp < -40 ? "black" : "equal";

  const displayScore =
    score.type === "mate"
      ? score.value > 0
        ? `+M${Math.abs(score.value)}`
        : `-M${Math.abs(score.value)}`
      : formatScore(scoreCp);

  const whitePercentage = clampToPercentage(scoreCp);

  const evaluation = {
    score_cp: scoreCp,
    display_score: displayScore,
    white_percentage: parseFloat(whitePercentage.toFixed(2)),
    advantage: advantage,
    source: "stockfish_wasm",
  };

  // Include best move if available
  if (score.bestMove) {
    evaluation.best_move = parseBestMove(score.bestMove);
  }

  return evaluation;
}

/**
 * Parse UCI move format (e.g., "e2e4", "e7e8q") into structured format
 */
function parseBestMove(uciMove) {
  if (!uciMove || uciMove.length < 4) return null;

  const from = uciMove.substring(0, 2);
  const to = uciMove.substring(2, 4);
  const promotion = uciMove.length > 4 ? uciMove.substring(4, 5) : "q";

  return {
    from: from,
    to: to,
    promotion: promotion,
    uci: uciMove,
  };
}

function formatScore(cp) {
  const pawns = cp / 100;
  return pawns >= 0 ? `+${pawns.toFixed(2)}` : pawns.toFixed(2);
}

function clampToPercentage(cp) {
  // Convert centipawns to percentage using a sigmoid-like function
  // Similar to the server-side implementation
  const cappedCp = Math.max(-1500, Math.min(1500, cp));
  const normalized = cappedCp / 1500; // -1 to 1
  // Map to 0-100% with a smoother curve
  return 50 + normalized * 50;
}

export function stopEvaluation() {
  if (stockfishWorker && isEngineReady) {
    stockfishWorker.postMessage("stop");
    pendingEvaluations.clear();
  }
}

export function shutdownEngine() {
  if (stockfishWorker) {
    stockfishWorker.postMessage("quit");
    stockfishWorker = null;
    isEngineReady = false;
    pendingEvaluations.clear();
  }
}
