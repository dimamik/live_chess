/**
 * Canvas-based particle animation system for endgame overlays
 * Provides smooth, performant animations for confetti and tears
 */

class ParticleSystem {
  constructor(canvas, type = "celebration") {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.type = type;
    this.particles = [];
    this.animationFrame = null;
    this.isRunning = false;
    this.canSpawnNew = true; // Control whether to spawn new particles

    this.resize();
    window.addEventListener("resize", () => this.resize());
  }

  resize() {
    this.canvas.width = window.innerWidth;
    this.canvas.height = window.innerHeight;
  }

  start() {
    if (this.isRunning) return;
    this.isRunning = true;

    if (this.type === "celebration") {
      this.createConfetti();
      // Stop ALL confetti animation after 5 seconds
      setTimeout(() => {
        this.canSpawnNew = false;
        // Remove all confetti particles after 5 seconds
        this.particles = [];
      }, 5000);
    } else {
      this.createTears();
      // Tears never stop spawning
    }

    this.animate();
  }

  stop() {
    this.isRunning = false;
    if (this.animationFrame) {
      cancelAnimationFrame(this.animationFrame);
      this.animationFrame = null;
    }
  }

  stopSpawning() {
    // Stop spawning new particles but let existing ones finish
    this.canSpawnNew = false;
  }

  clear() {
    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.particles = [];
    this.stop();
  }

  createConfetti() {
    const colors = [
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
      "#ec4899",
    ];

    const count = 120;

    for (let i = 0; i < count; i++) {
      this.particles.push({
        x: Math.random() * this.canvas.width,
        y: -20 - Math.random() * 200, // Like tears
        width: 8 + Math.random() * 8,
        height: 12 + Math.random() * 12,
        color: colors[Math.floor(Math.random() * colors.length)],
        rotation: Math.random() * 360,
        rotationSpeed: (Math.random() - 0.5) * 6,
        velocityY: 2 + Math.random() * 2.5, // Same as tears
        velocityX: (Math.random() - 0.5) * 1.5,
        gravity: 0.1,
        drift: Math.sin(Math.random() * Math.PI * 2) * 0.4,
        opacity: 1,
        delay: Math.random() * 2000, // Staggered like tears
      });
    }
  }

  createTears() {
    const count = 150; // Reduced from 350

    for (let i = 0; i < count; i++) {
      const size = 8 + Math.random() * 10; // Bigger: was 5-12, now 8-18
      this.particles.push({
        x: Math.random() * this.canvas.width,
        y: -20 - Math.random() * 200,
        width: size,
        height: size * 2,
        velocityY: 2.5 + Math.random() * 3,
        velocityX: (Math.random() - 0.5) * 0.6,
        wobble: Math.random() * Math.PI * 2,
        wobbleSpeed: 0.06 + Math.random() * 0.05,
        opacity: 0.75 + Math.random() * 0.25,
        shimmer: Math.random() * Math.PI * 2,
        shimmerSpeed: 0.08,
        delay: Math.random() * 2000,
        trail: [],
      });
    }
  }

  animate() {
    if (!this.isRunning) return;

    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);

    const now = Date.now();

    this.particles.forEach((particle, index) => {
      if (particle.delay > 0) {
        particle.delay -= 16; // ~60fps
        return;
      }

      if (this.type === "celebration") {
        this.updateConfetti(particle);
        this.drawConfetti(particle);
      } else {
        this.updateTear(particle);
        this.drawTear(particle);
      }

      // Respawn particles that are off screen (continuous loop)
      if (particle.y > this.canvas.height + 50) {
        // Only respawn if we're allowed to spawn new particles
        if (this.canSpawnNew) {
          this.respawnParticle(particle, index);
        } else {
          // Remove the particle if we can't spawn new ones
          this.particles.splice(index, 1);
        }
      }
    });

    // Keep animating continuously while there are particles
    if (this.particles.length > 0) {
      this.animationFrame = requestAnimationFrame(() => this.animate());
    } else {
      this.isRunning = false;
    }
  }

  respawnParticle(particle, index) {
    if (this.type === "celebration") {
      const colors = [
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
        "#ec4899",
      ];

      particle.x = Math.random() * this.canvas.width;
      particle.y = -20 - Math.random() * 100;
      particle.color = colors[Math.floor(Math.random() * colors.length)];
      particle.rotation = Math.random() * 360;
      particle.velocityY = 2 + Math.random() * 2.5;
      particle.velocityX = (Math.random() - 0.5) * 1.5;
      particle.opacity = 1;
      particle.delay = 0;
    } else {
      particle.x = Math.random() * this.canvas.width;
      particle.y = -20 - Math.random() * 200;
      particle.velocityY = 2.5 + Math.random() * 3;
      particle.velocityX = (Math.random() - 0.5) * 0.6;
      particle.wobble = Math.random() * Math.PI * 2;
      particle.opacity = 0.75 + Math.random() * 0.25;
      particle.trail = [];
      particle.delay = 0;
    }
  }

  updateConfetti(particle) {
    particle.velocityY += particle.gravity;
    particle.y += particle.velocityY;
    particle.x +=
      particle.velocityX + Math.sin(particle.y * 0.01) * particle.drift;
    particle.rotation += particle.rotationSpeed;

    // Keep opacity high throughout
    if (particle.y > this.canvas.height - 200) {
      particle.opacity = Math.max(0.3, particle.opacity - 0.005);
    }
  }

  updateTear(particle) {
    particle.y += particle.velocityY;
    particle.wobble += particle.wobbleSpeed;
    particle.shimmer += particle.shimmerSpeed;
    particle.x += Math.sin(particle.wobble) * 0.5 + particle.velocityX;

    // Reduced trail length for performance
    particle.trail.push({ x: particle.x, y: particle.y });
    if (particle.trail.length > 4) {
      // Reduced from 8
      particle.trail.shift();
    }

    // Keep opacity high - tears never fade out
  }

  drawConfetti(particle) {
    if (particle.opacity <= 0) return;

    this.ctx.save();
    this.ctx.translate(particle.x, particle.y);
    this.ctx.rotate((particle.rotation * Math.PI) / 180);
    this.ctx.globalAlpha = Math.max(0.3, particle.opacity);

    // Removed expensive shadows - just draw the confetti
    this.ctx.fillStyle = particle.color;
    this.ctx.fillRect(
      -particle.width / 2,
      -particle.height / 2,
      particle.width,
      particle.height
    );

    // Simple highlight (no gradient)
    this.ctx.fillStyle = "rgba(255, 255, 255, 0.4)";
    this.ctx.fillRect(
      -particle.width / 2,
      -particle.height / 2,
      particle.width,
      particle.height / 4
    );

    this.ctx.restore();
  }

  drawTear(particle) {
    if (particle.opacity <= 0) return;

    this.ctx.save();
    this.ctx.globalAlpha = particle.opacity;

    const shimmerAmount = Math.sin(particle.shimmer) * 0.15 + 0.85;

    // Draw simple teardrop: circle on top, triangle on bottom
    this.ctx.beginPath();

    const circleY = particle.y + particle.width * 0.5;
    this.ctx.arc(particle.x, circleY, particle.width * 0.5, 0, Math.PI * 2);

    this.ctx.moveTo(particle.x - particle.width * 0.5, circleY);
    this.ctx.lineTo(particle.x, particle.y + particle.height);
    this.ctx.lineTo(particle.x + particle.width * 0.5, circleY);

    this.ctx.closePath();

    // Simplified gradient (fewer stops)
    const gradient = this.ctx.createLinearGradient(
      particle.x,
      particle.y,
      particle.x,
      particle.y + particle.height
    );
    gradient.addColorStop(0, `rgba(191, 219, 254, ${shimmerAmount})`);
    gradient.addColorStop(1, `rgba(96, 165, 250, ${shimmerAmount * 0.8})`);

    this.ctx.fillStyle = gradient;
    this.ctx.fill();

    // Simple white highlight (no shadow)
    this.ctx.beginPath();
    this.ctx.arc(
      particle.x - particle.width * 0.2,
      circleY - particle.width * 0.15,
      particle.width * 0.25,
      0,
      Math.PI * 2
    );
    this.ctx.fillStyle = `rgba(255, 255, 255, ${shimmerAmount * 0.5})`;
    this.ctx.fill();

    this.ctx.restore();
  }
}

// Hook into Phoenix LiveView
export function initEndgameParticles() {
  window.addEventListener("phx:endgame-overlay", (e) => {
    const { type } = e.detail;

    // Remove existing canvas if any
    const existingCanvas = document.getElementById("endgame-particles-canvas");
    if (existingCanvas) {
      existingCanvas.remove();
    }

    // Create new canvas
    const canvas = document.createElement("canvas");
    canvas.id = "endgame-particles-canvas";
    canvas.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      pointer-events: none;
      z-index: 59;
    `;
    document.body.appendChild(canvas);

    // Start particle system
    const system = new ParticleSystem(canvas, type);
    system.start();

    // Store system reference globally so we can access it
    window.currentParticleSystem = system;

    // Clean up when overlay is dismissed
    const cleanup = () => {
      // Stop spawning new particles but let existing ones finish falling
      system.stopSpawning();

      // Clean up after particles have time to fall off screen
      setTimeout(() => {
        system.clear();
        canvas.remove();
        window.currentParticleSystem = null;
      }, 3000); // Give 3 seconds for particles to fall off screen

      document.removeEventListener("phx:dismiss-endgame-overlay", cleanup);
    };
    document.addEventListener("phx:dismiss-endgame-overlay", cleanup);
  });
}
