// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const tabStorageKey = "live_chess:tab_token";
let tabToken = sessionStorage.getItem(tabStorageKey);

if (!tabToken) {
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") {
    tabToken = globalThis.crypto.randomUUID();
  } else {
    tabToken = Array.from({ length: 32 }, () =>
      Math.floor(Math.random() * 16).toString(16)
    ).join("");
  }

  sessionStorage.setItem(tabStorageKey, tabToken);
}

const copyToClipboard = async (text) => {
  if (!text) return false;

  try {
    if (
      navigator.clipboard &&
      typeof navigator.clipboard.writeText === "function"
    ) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch (_error) {
    // Continue to fallback strategy.
  }

  try {
    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "absolute";
    textarea.style.left = "-9999px";
    textarea.style.opacity = "0";
    document.body.appendChild(textarea);

    const selection = document.getSelection();
    const selectedRange =
      selection && selection.rangeCount > 0 ? selection.getRangeAt(0) : null;

    textarea.select();
    textarea.setSelectionRange(0, textarea.value.length);

    const successful = document.execCommand("copy");

    document.body.removeChild(textarea);

    if (selectedRange && selection) {
      selection.removeAllRanges();
      selection.addRange(selectedRange);
    }

    return successful;
  } catch (_fallbackError) {
    return false;
  }
};

let audioContext;
let audioPrimed = false;

const getAudioContext = () => {
  if (typeof window === "undefined") return null;
  const Ctx = window.AudioContext || window.webkitAudioContext;
  if (!Ctx) return null;
  if (!audioContext) {
    audioContext = new Ctx();
  }
  return audioContext;
};

const resumeAudioContext = async () => {
  const ctx = getAudioContext();
  if (ctx && ctx.state === "suspended") {
    try {
      await ctx.resume();
    } catch (_error) {
      // Browsers may prevent auto-resume without a user gesture.
    }
  }
  return ctx;
};

const scheduleTone = (ctx, frequency, options = {}) => {
  if (!ctx) return;
  const { duration = 0.18, type = "sine", gain = 0.18, delay = 0 } = options;
  const oscillator = ctx.createOscillator();
  const gainNode = ctx.createGain();

  oscillator.type = type;
  oscillator.frequency.setValueAtTime(frequency, ctx.currentTime + delay);

  gainNode.gain.setValueAtTime(gain, ctx.currentTime + delay);
  gainNode.gain.exponentialRampToValueAtTime(
    0.0001,
    ctx.currentTime + delay + duration
  );

  oscillator.connect(gainNode).connect(ctx.destination);
  oscillator.start(ctx.currentTime + delay);
  oscillator.stop(ctx.currentTime + delay + duration + 0.05);
};

const playMoveSound = async () => {
  const ctx = await resumeAudioContext();
  if (!ctx) return;

  scheduleTone(ctx, 520, { duration: 0.14, type: "triangle", gain: 0.22 });
  scheduleTone(ctx, 660, {
    duration: 0.16,
    type: "triangle",
    gain: 0.18,
    delay: 0.1,
  });
};

const playJoinSound = async () => {
  const ctx = await resumeAudioContext();
  if (!ctx) return;

  scheduleTone(ctx, 440, { duration: 0.16, type: "sine", gain: 0.18 });
  scheduleTone(ctx, 660, {
    duration: 0.2,
    type: "sine",
    gain: 0.16,
    delay: 0.12,
  });
};

// Detect iOS devices
const detectiOS = () => {
  if (typeof navigator === "undefined") {
    return false;
  }
  const toMatch = [/iPhone/i, /iPad/i, /iPod/i];
  return toMatch.some((toMatchItem) => {
    return RegExp(toMatchItem).exec(navigator.userAgent);
  });
};

// Detect Android devices
const detectAndroid = () => {
  if (typeof navigator === "undefined") {
    return false;
  }
  const toMatch = [/Android/i, /webOS/i, /BlackBerry/i, /Windows Phone/i];
  return toMatch.some((toMatchItem) => {
    return RegExp(toMatchItem).exec(navigator.userAgent);
  });
};

// Haptic feedback setup for iOS (using Safari 18.0+ input[switch] feature)
// Based on https://github.com/posaune0423/use-haptic
// CRITICAL: This must be triggered synchronously during a user interaction event
let hapticInput = null;
let hapticLabel = null;

const setupHapticElements = () => {
  // Only set up for iOS devices
  if (!detectiOS() || hapticInput) {
    return;
  }

  try {
    // Create input[type="checkbox"][switch] for iOS haptic feedback
    hapticInput = document.createElement("input");
    hapticInput.type = "checkbox";
    hapticInput.id = "haptic-switch";
    hapticInput.setAttribute("switch", "");
    hapticInput.style.cssText = "display: none;";

    // Create label associated with the input
    hapticLabel = document.createElement("label");
    hapticLabel.htmlFor = "haptic-switch";
    hapticLabel.style.cssText = "display: none;";

    // Append directly to body
    document.body.appendChild(hapticInput);
    document.body.appendChild(hapticLabel);

    console.log("iOS haptic feedback initialized");
  } catch (error) {
    console.error("Failed to setup haptic elements:", error);
  }
};

// Initialize haptic elements when DOM is ready
if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setupHapticElements);
  } else {
    setupHapticElements();
  }
}

// Vibration helpers for mobile devices
// MUST be called synchronously during a user interaction event for iOS haptic to work
const vibrateDevice = (pattern) => {
  const isIOS = detectiOS();

  if (isIOS) {
    // Ensure elements are set up
    if (!hapticLabel) {
      setupHapticElements();
    }

    if (hapticLabel) {
      try {
        // Click the label synchronously during user interaction
        // This triggers the checkbox which provides native haptic feedback on iOS
        hapticLabel.click();
      } catch (error) {
        console.debug("iOS haptic failed:", error);
      }
    }
  } else if (typeof navigator !== "undefined" && navigator.vibrate) {
    // Use Vibration API for Android and other devices
    try {
      navigator.vibrate(pattern);
    } catch (error) {
      console.debug("Vibration failed:", error);
    }
  }
};

const vibrateOnMove = () => {
  // Short single vibration for moves (50ms)
  vibrateDevice(50);
};

const vibrateOnOpponentMove = () => {
  // Slightly longer vibration for opponent moves (80ms)
  vibrateDevice(80);
};

const vibrateOnJoin = () => {
  // Two short vibrations for player joining
  vibrateDevice([60, 40, 60]);
};

import {
  initStockfish,
  evaluatePosition,
  stopEvaluation,
} from "./stockfish-client.js";

import { initEndgameParticles } from "./endgame-particles.js";

const Hooks = {
  ChessBoard: {
    mounted() {
      // Attach haptic feedback to square clicks
      // This MUST be called synchronously during the user's click event
      this.handleSquareClick = (event) => {
        // Check if clicking on a button (chess square)
        const button = event.target.closest(
          'button[phx-click="select_square"]'
        );
        if (button) {
          // Only trigger haptic if this square has a move-dot
          // (meaning it's a valid move destination, not just selecting your piece)
          const hasMoveIndicator = button.querySelector(".move-dot") !== null;

          if (hasMoveIndicator) {
            // Trigger haptic feedback immediately on move
            // For iOS, this toggles the hidden checkbox which triggers native haptic
            // For Android, this calls navigator.vibrate()
            vibrateDevice(50);
          }
        }
      };

      // Listen for clicks - must be synchronous with user interaction
      // Use capture phase to ensure we catch it before LiveView
      this.el.addEventListener("click", this.handleSquareClick, {
        capture: true,
      });
    },
    destroyed() {
      if (this.handleSquareClick) {
        this.el.removeEventListener("click", this.handleSquareClick, {
          capture: true,
        });
      }
    },
  },
  StockfishEvaluator: {
    mounted() {
      // Get the Stockfish path from the data attribute (works with digested assets in production)
      const stockfishPath = this.el.dataset.stockfishPath;

      // Initialize Stockfish engine with the correct path
      initStockfish(stockfishPath).catch((err) => {
        console.error("Failed to initialize Stockfish:", err);
      });

      // Listen for evaluation requests from server
      this.handleEvent("request_client_eval", async ({ fen, depth }) => {
        try {
          const evaluation = await evaluatePosition(fen, {
            depth: depth || 12,
          });
          // Send evaluation back to server
          this.pushEvent("client_eval_result", { evaluation });
        } catch (err) {
          console.error("Evaluation failed:", err);
          this.pushEvent("client_eval_error", { error: err.message });
        }
      });

      // Listen for robot move requests from server
      this.handleEvent("request_robot_move", async ({ fen, depth }) => {
        try {
          const evaluation = await evaluatePosition(fen, {
            depth: depth || 12,
          });

          if (evaluation.best_move) {
            // Send the best move back to server for the robot to play
            this.pushEvent("robot_move_ready", { move: evaluation.best_move });
          } else {
            this.pushEvent("robot_move_error", { error: "No best move found" });
          }
        } catch (err) {
          console.error("Robot move failed:", err);
          this.pushEvent("robot_move_error", { error: err.message });
        }
      });
    },
    destroyed() {
      stopEvaluation();
    },
  },
  CopyShareLink: {
    mounted() {
      this.inputEl = this.el.querySelector("[data-share-input]");
      this.messageEl = this.el.querySelector("[data-copy-message]");
      this.copyUrl = this.el.dataset.url || this.inputEl?.value || "";
      this.successText =
        this.el.dataset.successText || "Link copied to clipboard";
      this.resetTimer = null;

      if (!this.inputEl) return;

      if (this.messageEl) {
        this.messageEl.setAttribute("aria-hidden", "true");
      }

      this.handleCopy = async (event) => {
        event.preventDefault();
        this.copyUrl =
          this.el.dataset.url || this.inputEl.value || this.copyUrl;

        if (!this.copyUrl) return;

        const didCopy = await copyToClipboard(this.copyUrl);

        if (!didCopy) {
          if (
            typeof window !== "undefined" &&
            typeof window.prompt === "function"
          ) {
            window.prompt("Copy this link", this.copyUrl);
          }
          return;
        }

        this.clearSelection();
        this.showMessage();
      };

      this.inputEl.addEventListener("click", this.handleCopy);
    },
    updated() {
      this.copyUrl = this.el.dataset.url || this.inputEl?.value || this.copyUrl;
    },
    destroyed() {
      if (this.inputEl && this.handleCopy) {
        this.inputEl.removeEventListener("click", this.handleCopy);
      }
      if (this.resetTimer) {
        clearTimeout(this.resetTimer);
        this.resetTimer = null;
      }
    },
    showMessage() {
      if (!this.messageEl) return;

      this.messageEl.textContent = this.successText;
      this.messageEl.classList.remove("hidden");
      this.messageEl.setAttribute("aria-hidden", "false");

      if (this.resetTimer) {
        clearTimeout(this.resetTimer);
      }

      this.resetTimer = setTimeout(() => {
        this.messageEl.classList.add("hidden");
        this.messageEl.setAttribute("aria-hidden", "true");
      }, 2000);
    },
    clearSelection() {
      if (typeof window === "undefined") return;
      if (typeof this.inputEl?.blur === "function") {
        this.inputEl.blur();
      }
      const selection = window.getSelection ? window.getSelection() : null;
      if (selection && typeof selection.removeAllRanges === "function") {
        selection.removeAllRanges();
      }
    },
  },
  SoundEffects: {
    mounted() {
      if (!audioPrimed) {
        const prime = () => {
          audioPrimed = true;
          resumeAudioContext();
        };

        window.addEventListener("pointerdown", prime, {
          once: true,
          passive: true,
        });
        window.addEventListener("keydown", prime, { once: true });
      }

      this.handleEvent("play-move-sound", playMoveSound);
      this.handleEvent("play-join-sound", playJoinSound);

      // Vibration events
      this.handleEvent("vibrate-move", vibrateOnMove);
      this.handleEvent("vibrate-opponent-move", vibrateOnOpponentMove);
      this.handleEvent("vibrate-join", vibrateOnJoin);

      resumeAudioContext();
    },
  },

  EndgameCanvas: {
    mounted() {
      const overlayType = this.el.dataset.overlayType;

      // Dispatch event to trigger canvas particles
      window.dispatchEvent(
        new CustomEvent("phx:endgame-overlay", {
          detail: { type: overlayType },
        })
      );

      // Store reference for cleanup
      this.cleanupTriggered = false;
    },

    destroyed() {
      // Trigger cleanup if not already done
      if (!this.cleanupTriggered) {
        this.cleanupTriggered = true;
        window.dispatchEvent(new CustomEvent("phx:dismiss-endgame-overlay"));
      }
    },

    beforeUpdate() {
      // Trigger cleanup before component updates/removes
      if (!this.cleanupTriggered) {
        this.cleanupTriggered = true;
        window.dispatchEvent(new CustomEvent("phx:dismiss-endgame-overlay"));
      }
    },
  },
};

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken, player_token: tabToken },
  hooks: Hooks,
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// Initialize endgame particle system
initEndgameParticles();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true
      );

      window.liveReloader = reloader;
    }
  );
}
