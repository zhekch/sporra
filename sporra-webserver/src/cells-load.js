// Getting the account's cells onto the map without stopping it.
//
// Signing in used to be one long task on the main thread: parse 26 MB of JSON,
// file 595k rows into `visited` and `cellMeta`, roll them up through seven
// levels — and then, because the preferences arrived afterwards, roll them up
// again. Measured in WebKit on that account it froze the page for 712 ms and
// then for another 503, squarely in the middle of the camera flying in, which is
// the one moment anybody is watching the map move.
//
// None of it has to be one task. The parse goes to a worker (src/cells-worker.js)
// and the rest is cut into slices of SLICE_MS with the browser given a frame in
// between. It takes about as long in total; the difference is that the fly-in
// keeps its frames while it happens, and the ring at the top of the screen says
// what is going on.

// How long one slice may hold the main thread. Half a 60 Hz frame, so the map's
// own work for the frame still fits beside it.
export const SLICE_MS = 8;

/** Let the browser draw a frame, then carry on. */
export function nextFrame() {
  return new Promise((resolve) => {
    // A hidden tab never runs rAF; the timeout is what keeps a sign-in in a
    // background tab from stalling until somebody looks at it.
    let done = false;
    const go = () => {
      if (done) return;
      done = true;
      resolve();
    };
    if (typeof requestAnimationFrame === 'function') requestAnimationFrame(() => setTimeout(go, 0));
    setTimeout(go, 50);
  });
}

/**
 * Drive a generator to completion, a slice at a time.
 *
 * The generator yields whenever it is at a point where stopping is safe; this
 * decides whether the slice has run long enough to actually stop there. Returns
 * whatever the generator returns.
 *
 * @param {Generator} gen
 * @param {() => boolean} [stillWanted]  asked between slices; false abandons
 *   the work and resolves to undefined
 */
export async function runSliced(gen, stillWanted = () => true) {
  let t0 = performance.now();
  for (;;) {
    const step = gen.next();
    if (step.done) return step.value;
    if (performance.now() - t0 >= SLICE_MS) {
      await nextFrame();
      if (!stillWanted()) {
        gen.return?.();
        return undefined;
      }
      t0 = performance.now();
    }
  }
}

// --- Parsing --------------------------------------------------------------------

/**
 * The same columns the worker produces, worked out here. For a browser with no
 * worker to give it, or a worker that failed — slower for the page, never wrong.
 */
export function parseCellsBuffer(buffer) {
  const { sources = [], rows = [] } = JSON.parse(new TextDecoder().decode(buffer)) ?? {};
  const n = rows.length;
  const ids = new Array(n);
  const visitDates = rows.map(r => r[7] ?? []);
  const src = new Uint16Array(n);
  const cols = [new Float64Array(n), new Float64Array(n), new Float64Array(n), new Float64Array(n), new Float64Array(n)];
  for (let i = 0; i < n; i++) {
    const r = rows[i];
    ids[i] = r[0];
    src[i] = r[1] ?? 65535;
    for (let c = 0; c < 5; c++) {
      const v = r[c + 2];
      cols[c][i] = v == null ? (c === 4 && v === undefined ? 0 : NaN) : v;
    }
  }
  return { sources, ids: ids.join('\n'), n, src, cols, visitDates };
}

let worker = null;
let workerBroken = false;
let nextId = 1;
const waiting = new Map();

function getWorker() {
  if (worker || workerBroken || typeof Worker !== 'function') return worker;
  try {
    worker = new Worker(new URL('./cells-worker.js', import.meta.url));
    worker.onmessage = ({ data }) => {
      const w = waiting.get(data.id);
      if (!w) return;
      waiting.delete(data.id);
      if (data.error) w.reject(new Error(data.error));
      else w.resolve(data);
    };
    // A worker that cannot start at all — a policy that refuses it, a web view
    // that does not host them — fails everything it was holding, and is not
    // asked again this session.
    worker.onerror = (e) => {
      e.preventDefault?.();
      workerBroken = true;
      worker = null;
      for (const w of waiting.values()) w.reject(new Error('cells worker failed'));
      waiting.clear();
    };
  } catch {
    workerBroken = true;
    worker = null;
  }
  return worker;
}

/**
 * Parse a `/api/cells` body into columns: `{ sources, ids, n, src, cols, visitDates }`,
 * where `ids` is every row's cell id joined by newlines — one string rather than
 * 595k, because splitting it here would be the very block this avoids; the
 * filling walks it instead — and `cols` is added, first, last, hits and fixes,
 * NaN for a missing value.
 * Off the main thread where possible; the buffer is handed over, so the caller
 * must not read it afterwards.
 *
 * @param {ArrayBuffer} buffer
 */
export async function parseCells(buffer) {
  const w = getWorker();
  if (w) {
    // Kept in case the worker dies with it: the fallback needs the bytes, and
    // a transferred buffer is gone from this side.
    const copy = buffer.slice(0);
    try {
      return await new Promise((resolve, reject) => {
        const id = nextId++;
        waiting.set(id, { resolve, reject });
        w.postMessage({ id, buffer }, [buffer]);
      });
    } catch {
      return parseCellsBuffer(copy);
    }
  }
  return parseCellsBuffer(buffer);
}

/**
 * File the parsed rows into `visited` and `cellMeta`, yielding as it goes.
 * A generator for runSliced.
 */
export function* fillCells(parsed, visited, cellMeta) {
  const { sources, ids, n, src, cols, visitDates } = parsed;
  const [added, first, last, hits, fixes] = cols;
  const num = (v) => (Number.isNaN(v) ? null : v);
  let at = 0;
  for (let i = 0; i < n; i++) {
    let end = ids.indexOf('\n', at);
    if (end < 0) end = ids.length;
    const id = ids.slice(at, end);
    at = end + 1;
    visited.add(id);
    const entry = {
      source: sources[src[i]] ?? 'unknown',
      addedAt: num(added[i]),
      firstAt: num(first[i]),
      lastAt: num(last[i]),
      hits: num(hits[i]),
      fixes: num(fixes[i]),
      ...(visitDates?.[i]?.length ? { visitDates: visitDates[i] } : {}),
    };
    const list = cellMeta.get(id);
    if (list) list.push(entry);
    else cellMeta.set(id, [entry]);
    if ((i & 2047) === 2047) yield;
  }
}
