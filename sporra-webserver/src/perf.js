// Load with ?perf to have the costs that decide whether a phone keeps up
// written to the console: how long the roll-up and each blob paint take, and,
// for every gesture, how its frames were spaced. Off, every function here is a
// pass-through.
//
// It exists because every performance question on this project has been
// answered wrongly at least once by looking — a map that feels slow on one
// device is a number on another. Read it in Safari's Web Inspector attached to
// the iOS app, which is the client this was built to measure.

export const PERF = typeof location !== 'undefined' && new URLSearchParams(location.search).has('perf');

/** Run `fn`, and with ?perf say how long it took. Returns what `fn` returns. */
export function span(name, fn) {
  if (!PERF) return fn();
  const t0 = performance.now();
  try {
    return fn();
  } finally {
    const ms = performance.now() - t0;
    try {
      performance.measure(`sporra:${name}`, { start: t0, duration: ms });
    } catch {
      /* an older WebKit without the options form; the log line is the point */
    }
    console.log(`[perf] ${name} ${ms.toFixed(1)} ms`);
  }
}

// --- Frames, per gesture --------------------------------------------------------
let frames = null;
let raf = 0;
let last = 0;

function tick(now) {
  if (!frames) return;
  if (last) frames.push(now - last);
  last = now;
  raf = requestAnimationFrame(tick);
}

/** Start timing frames — at `movestart`. */
export function gestureStart() {
  if (!PERF || frames) return;
  frames = [];
  last = 0;
  raf = requestAnimationFrame(tick);
}

/** Stop, and log one line for the gesture — at `moveend`. */
export function gestureEnd() {
  if (!PERF || !frames) return;
  cancelAnimationFrame(raf);
  const f = frames.sort((a, b) => a - b);
  frames = null;
  if (!f.length) return;
  const at = (q) => f[Math.min(f.length - 1, Math.floor(q * f.length))].toFixed(1);
  const long = f.filter((d) => d > 33.4).length;
  console.log(`[perf] gesture: ${f.length} frames, p50 ${at(0.5)} ms, p95 ${at(0.95)} ms, ${long} over 33 ms`);
}
