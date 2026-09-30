// The blob paint asks src/cell-index.js where the lit cells are instead of
// walking every one of them. That is only a speed-up if it is the same picture,
// so two things are pinned here:
//
//   1. The index answers a window exactly — every filed cell inside it, none
//      outside — before and after cells are added and taken away, including
//      negative rows and a window reaching past either end of the lattice.
//   2. paintBlobSheet draws exactly the same discs, in the same colours at the
//      same radii, with the index as without it, across world copies and the
//      antimeridian. The canvas is stubbed: what is compared is the list of
//      arcs handed to each fill, which is everything the pixels are made from.
//
//   node scripts/test/cell-index.mjs

import { createCellIndex, indexCells, CELL_BUCKET } from '../../src/cell-index.js';
import { colsOf, radiusOf, SQRT3 } from '../../src/hexgrid.js';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

// A small deterministic generator, so a failure is the same failure next time.
let seed = 12345;
const rand = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
const randInt = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));

console.log('\nThe index answers a window exactly');
{
  const index = createCellIndex();
  const all = new Map(); // key → [col, row]
  const put = (col, row) => {
    const key = `${col}/${row}`;
    all.set(key, [col, row]);
    index.add(key, col, row);
  };
  for (let i = 0; i < 4000; i++) put(randInt(0, 2000), randInt(-900, 900));
  // A clump straddling bucket edges, where an off-by-one would show.
  for (let c = CELL_BUCKET - 3; c <= CELL_BUCKET + 3; c++) {
    for (let r = -3; r <= 3; r++) put(c, r);
  }

  const agree = (label) => {
    let bad = null;
    for (let t = 0; t < 200 && !bad; t++) {
      const c0 = randInt(-100, 2100);
      const r0 = randInt(-1000, 1000);
      const c1 = c0 + randInt(0, t % 10 === 0 ? 5000 : 300);
      const r1 = r0 + randInt(0, 400);
      const want = [...all].filter(([, [c, r]]) => c >= c0 && c <= c1 && r >= r0 && r <= r1).map(([k]) => k).sort();
      const got = [];
      index.forEachIn(c0, c1, r0, r1, (k, c, r) => {
        if (all.get(k)?.[0] !== c || all.get(k)?.[1] !== r) bad = `${k} came back as ${c}/${r}`;
        got.push(k);
      });
      got.sort();
      if (!bad && got.join() !== want.join()) bad = `window ${c0}..${c1} × ${r0}..${r1}: ${got.length} against ${want.length}`;
    }
    check(!bad, label, bad);
  };
  agree('two hundred windows, against a brute-force filter');

  // Take half of them away again, and put some back twice.
  let n = 0;
  for (const [key, [c, r]] of [...all]) {
    if (n++ % 2) continue;
    all.delete(key);
    index.remove(key, c, r);
  }
  for (let i = 0; i < 500; i++) {
    const c = randInt(0, 2000);
    const r = randInt(-900, 900);
    put(c, r);
    put(c, r);
  }
  index.remove('999999/999999', 999999, 999999); // never filed — a no-op, not a throw
  agree('and again after removals and repeated adds');
  check(index.size === all.size, 'its size follows what is filed', `${index.size} against ${all.size}`);

  const built = indexCells(new Map([...all.keys()].map((k) => [k, {}])));
  let same = built.size === index.size;
  built.forEachIn(-Infinity, Infinity, -Infinity, Infinity, (k) => {
    if (!all.has(k)) same = false;
  });
  check(same, 'indexCells files every key of a Map');
}

// --- paintBlobSheet, with and without it ----------------------------------------

// Path2D records the arcs it is given; each context records what it filled.
class Path2DStub {
  constructor() {
    this.arcs = [];
  }
  moveTo() {}
  arc(x, y, r) {
    this.arcs.push(`${x.toFixed(6)},${y.toFixed(6)},${r.toFixed(6)}`);
  }
}
globalThis.Path2D = Path2DStub;

function stubContext(canvas, log) {
  const state = { fillStyle: '' };
  return new Proxy(state, {
    get(target, prop) {
      if (prop in target) return target[prop];
      if (prop === 'canvas') return canvas;
      if (prop === 'fill') {
        return (path) => {
          if (log && path) log.push(...path.arcs.map((a) => `${target.fillStyle}@${a}`));
        };
      }
      if (prop === 'getImageData' || prop === 'createImageData') {
        return (...a) => {
          const w = Math.max(1, Math.round(a.length >= 4 ? a[2] : a[0]));
          const h = Math.max(1, Math.round(a.length >= 4 ? a[3] : a[1]));
          return { width: w, height: h, data: new Uint8ClampedArray(w * h * 4) };
        };
      }
      return () => {};
    },
    set(target, prop, value) {
      target[prop] = value;
      return true;
    },
  });
}

function stubBuffers(log) {
  const make = (name) => {
    const canvas = { width: 0, height: 0 };
    return [canvas, stubContext(canvas, name === 'sheet' ? log : null)];
  };
  const [latest, latestCtx] = make('latest');
  const [sheet, sheetCtx] = make('sheet');
  const [work, workCtx] = make('work');
  return { latest, latestCtx, sheet, sheetCtx, work, workCtx };
}

const { paintBlobSheet } = await import('../../src/blob-canvas.js');

function discs(opts) {
  const log = [];
  paintBlobSheet({ ...opts, buffers: stubBuffers(log) });
  return log.sort();
}

console.log('\nThe blob paint draws the same discs with the index as without it');
{
  const colours = ['#f00', '#0f0', '#00f'];
  for (const level of [0, 2, 4]) {
    const N = colsOf(level);
    const R = radiusOf(level);
    const colSp = 1.5 * R;
    const rowSp = SQRT3 * R;
    const cells = new Map();
    // A town's worth of cells, some lone ones, and a run across the
    // antimeridian so both ends of the lattice are lit.
    const c0 = randInt(0, N - 1);
    const r0 = randInt(-2000, 2000);
    for (let i = 0; i < 3000; i++) {
      const c = (c0 + randInt(-60, 60) + N) % N;
      cells.set(`${c}/${r0 + randInt(-60, 60)}`, { v: randInt(0, 2) });
    }
    for (let i = 0; i < 40; i++) cells.set(`${(N - 20 + i) % N}/${r0 + (i % 5)}`, { v: i % 3 });
    const index = indexCells(cells);
    const colorOf = (s) => colours[s.v];

    const boxAround = (col, row, halfCols, halfRows) => ({
      xMin: (col - halfCols) * colSp,
      xMax: (col + halfCols) * colSp,
      yMin: (row - halfRows) * rowSp,
      yMax: (row + halfRows) * rowSp,
    });
    const windows = [
      ['the town', boxAround(c0, r0, 40, 60)],
      ['its edge', boxAround(c0 + 55, r0 - 50, 30, 30)],
      ['the antimeridian', boxAround(N, r0, 30, 20)],
      ['two world copies', boxAround(0, r0, N * 0.75, 80)],
      ['nowhere lit', boxAround(c0 + 500, r0 + 900, 20, 20)],
    ];
    for (const [name, bb] of windows) {
      const pxPerMerc = 300 / (bb.xMax - bb.xMin);
      const base = { bb, level, cells, colorOf, pxPerMerc };
      const scan = discs(base);
      const indexed = discs({ ...base, index });
      const same = scan.length === indexed.length && scan.every((d, i) => d === indexed[i]);
      check(same, `level ${level}, ${name}: ${scan.length} discs either way`,
        `${scan.length} scanned, ${indexed.length} indexed`);
    }
  }
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
