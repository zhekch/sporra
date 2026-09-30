// Signing in parses the cells in a worker and files them in slices
// (src/cells-load.js). The map reads `visited` and `cellMeta` exactly as it did
// when they were filled in one loop over `res.json()`, so that is what is held
// here: the columns the worker produces, filed back, give the same two
// structures the old loop did — missing numbers, a missing `fixes`, one cell
// under several sources and all. The worker itself is the same code as
// parseCellsBuffer, run here directly, since Node has no Worker at this path.
//
//   node scripts/test/cells-load.mjs

import { readFileSync } from 'node:fs';
import { parseCellsBuffer, fillCells, runSliced } from '../../src/cells-load.js';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

const body = {
  sources: ['strava', 'manual', 'google-timeline'],
  rows: [
    ['0/10/20', 0, 1700000000, 1600000000, 1700000500, 3, 12],
    ['0/10/20', 2, 1700000001, 1500000000, 1690000000, 9, 0],
    ['0/11/20', 1, 1700000002, 0, 0, 1, 0],
    ['0/12/21', 0, 1700000003, null, 1650000000, 2, null], // a null that must stay null
    ['1/4/7', 7, 1700000004, 1, 2, 5], // no fixes at all, and a source index past the list
  ],
};

// The loop this replaced, verbatim in what it builds.
function oldFill({ sources = [], rows = [] }) {
  const visited = new Set();
  const cellMeta = new Map();
  for (const [id, srcIdx, addedAt, firstAt, lastAt, hits, fixes = 0] of rows) {
    visited.add(id);
    const entry = { source: sources[srcIdx] ?? 'unknown', addedAt, firstAt, lastAt, hits, fixes };
    const list = cellMeta.get(id);
    if (list) list.push(entry);
    else cellMeta.set(id, [entry]);
  }
  return { visited, cellMeta };
}

const drain = (gen) => {
  for (let s = gen.next(); !s.done; s = gen.next());
};

console.log('\nThe columns file back into what the old loop built');
{
  const want = oldFill(body);
  const parsed = parseCellsBuffer(new TextEncoder().encode(JSON.stringify(body)).buffer);
  check(parsed.n === body.rows.length && typeof parsed.ids === 'string', 'one row per row, the ids as one string');
  const visited = new Set();
  const cellMeta = new Map();
  drain(fillCells(parsed, visited, cellMeta));
  check([...visited].join() === [...want.visited].join(), 'the same cells, in the same order');
  const same = JSON.stringify([...cellMeta]) === JSON.stringify([...want.cellMeta]);
  check(same, 'the same provenance under each, nulls and defaults included',
    `${JSON.stringify([...cellMeta])}\n    against ${JSON.stringify([...want.cellMeta])}`);

  // What the worker module itself does, against the same body: its source is
  // the same arithmetic, and a drift between the two would only show in a
  // browser that has workers — which is every one this ships to.
  const worker = readFileSync(new URL('../../src/cells-worker.js', import.meta.url), 'utf8');
  let posted = null;
  const self = { postMessage: (m) => (posted = m) };
  new Function('self', worker)(self);
  self.onmessage({ data: { id: 1, buffer: new TextEncoder().encode(JSON.stringify(body)).buffer } });
  const v2 = new Set();
  const m2 = new Map();
  drain(fillCells(posted, v2, m2));
  check(JSON.stringify([...m2]) === JSON.stringify([...want.cellMeta]), 'and the worker files back the same');

  const empty = parseCellsBuffer(new TextEncoder().encode('{"sources":[],"rows":[]}').buffer);
  const v3 = new Set();
  drain(fillCells(empty, v3, new Map()));
  check(v3.size === 0, 'an empty account files nothing — not one cell called ""');
}

console.log('\nA sliced run stops when it is no longer wanted');
{
  globalThis.requestAnimationFrame ??= (fn) => setTimeout(fn, 0);
  let steps = 0;
  function* slow() {
    for (let i = 0; i < 1e6; i++) {
      const t = performance.now();
      while (performance.now() - t < 1); // a millisecond of work a step
      steps++;
      yield;
    }
    return 'finished';
  }
  let wanted = true;
  setTimeout(() => (wanted = false), 60);
  const out = await runSliced(slow(), () => wanted);
  check(out === undefined && steps < 1e6, 'abandoned rather than run to the end', `${out} after ${steps}`);

  function* quick() {
    yield;
    yield;
    return 42;
  }
  check((await runSliced(quick())) === 42, 'and a short one returns what it returns');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
