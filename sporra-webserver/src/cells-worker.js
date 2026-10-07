// Parses the account's cells off the main thread.
//
// `/api/cells` is one row per cell per source — 595k rows, 26 MB of JSON, on
// the account this was written for — and `res.json()` parses it on the thread
// that draws the map. That was a single ~120 ms block in the middle of the
// camera's fly-in on a desktop, and more on a phone, before a cell had even been
// looked at. Here the bytes arrive transferred rather than copied, and go back
// the same way as columns: one string of ids and a typed array per number, all
// of it moved with the message instead of rebuilt on the other side.
//
// No imports, so it bundles as a classic worker — the build targets Safari 14,
// which has no module workers. See parseCellsBuffer in src/cells-load.js, which
// is the same thing on the main thread for when a worker cannot be had.

self.onmessage = (event) => {
  const { id, buffer } = event.data;
  try {
    const { sources = [], rows = [] } = JSON.parse(new TextDecoder().decode(buffer)) ?? {};
    const n = rows.length;
    const ids = new Array(n);
  const visitDates = rows.map(r => r[7] ?? []);
    const src = new Uint16Array(n);
    // A missing number is sent as NaN, which the reader turns back into the
    // null the JSON held — the columns cannot hold a null, and 0 means something.
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
    const out = { id, sources, ids: ids.join('\n'), n, src, cols, visitDates };
    self.postMessage(out, [src.buffer, ...cols.map((a) => a.buffer)]);
  } catch (error) {
    self.postMessage({ id, error: String(error?.message ?? error) });
  }
};
