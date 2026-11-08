// The roll-up is built level by level now, where it used to walk every stored
// cell up all seven levels. That is only a speed-up if every level comes out the
// same, so the old walk is kept here, verbatim in what it computes, and the two
// are compared field by field:
//
//   - hits, cells, time, age and the dominant source of every entry at every
//     level, and `near`, which is read off the entries above;
//   - the stored ids under every entry, which the old walk copied onto each
//     ancestor and the new one reads back down through `kids`;
//   - which stored cells are drawn, and the per-source count the palette is
//     handed out from, with and without a hidden source;
//
// and then the two incremental paths a brush uses — folding a painted cell in,
// taking an erased one out — against a rebuild from scratch.
//
//   node scripts/test/rollup.mjs

import { MAX_LEVEL, parentOf, parseCellId } from '../../src/hexgrid.js';
import { HEAT_NEIGHBOURHOOD } from '../../src/coloring.js';
import {
  rollUp, attachNeighbourhoods, dominantSource, storedUnder, foldInCell, removeCell,
} from '../../src/rollup.js';
import { indexCells } from '../../src/cell-index.js';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

let seed = 777;
const rand = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
const randInt = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));

// --- The walk this replaced -----------------------------------------------------

function addSourceOld(e, src, hits) {
  if (e.srcMap) e.srcMap.set(src, (e.srcMap.get(src) ?? 0) + hits);
  else if (e.src1 === undefined) {
    e.src1 = src;
    e.n1 = hits;
  } else if (e.src1 === src) e.n1 += hits;
  else e.srcMap = new Map([[e.src1, e.n1], [src, hits]]);
}

function rollUpOld(visited, statsOf, { byType = false, hidden = new Set() } = {}) {
  const litSets = Array.from({ length: MAX_LEVEL + 1 }, () => new Map());
  const sourceCells = new Map();
  const filtering = hidden.size > 0;
  const shown = filtering ? new Set() : null;
  for (const id of visited) {
    let [L, col, row] = parseCellId(id);
    if (!(L <= MAX_LEVEL)) {
      shown?.add(id);
      continue;
    }
    const { hits, time, age, own, ownN } = statsOf(id, byType || filtering);
    if (byType && own) sourceCells.set(own, (sourceCells.get(own) ?? 0) + 1);
    if (filtering && hidden.has(own)) continue;
    shown?.add(id);
    for (let l = L; l <= MAX_LEVEL; l++) {
      if (l > L) [col, row] = parentOf(l - 1, col, row);
      const key = `${col}/${row}`;
      let e = litSets[l].get(key);
      if (e) {
        e.hits += hits;
        e.cells++;
        e.ids.push(id);
        if (time > e.time) e.time = time;
        if (age && (!e.age || age < e.age)) e.age = age;
      } else {
        litSets[l].set(key, (e = { hits, time, age, cells: 1, ids: [id] }));
      }
      if (byType && own) addSourceOld(e, own, ownN);
    }
  }
  // The old neighbourhood, by key.
  for (let level = 0; level <= MAX_LEVEL; level++) {
    for (const [key, e] of litSets[level]) {
      const up = Math.min(MAX_LEVEL, level + HEAT_NEIGHBOURHOOD);
      const own = (x) => (x ? x.hits / x.cells : 0);
      if (up === level) {
        e.near = own(e);
        continue;
      }
      let [col, row] = key.split('/').map(Number);
      for (let l = level; l < up; l++) [col, row] = parentOf(l, col, row);
      e.near = own(litSets[up].get(`${col}/${row}`)) || own(e);
    }
  }
  return { litSets, sourceCells, shown };
}

// --- A made-up history ----------------------------------------------------------

const SOURCES = ['strava', 'komoot', 'google-timeline', 'manual'];

function makeHistory(n) {
  const ids = new Set();
  const meta = new Map();
  // Two towns and a road between them at level 0, a few cells stored a level or
  // two up (an old lattice's leftovers), and one id that does not parse.
  const towns = [[randInt(10_000, 600_000), randInt(-200_000, 200_000)], [0, 0]];
  towns[1] = [towns[0][0] + 400, towns[0][1] + 300];
  for (let i = 0; i < n; i++) {
    const [tc, tr] = towns[i % 2];
    const id = `0/${tc + randInt(-50, 50)}/${tr + randInt(-50, 50)}`;
    ids.add(id);
  }
  for (let i = 0; i < 400; i++) ids.add(`0/${towns[0][0] + i}/${towns[0][1] + Math.round(i * 0.75)}`);
  ids.add(`1/${Math.floor(towns[0][0] / 3)}/${Math.floor(towns[0][1] / 3)}`);
  ids.add(`2/${Math.floor(towns[1][0] / 9) + 5}/${Math.floor(towns[1][1] / 9)}`);
  ids.add('9/1/1');
  ids.add('not-a-cell');
  for (const id of ids) {
    const hits = randInt(1, 20);
    const dated = rand() < 0.8;
    meta.set(id, {
      hits,
      time: dated ? randInt(1_500_000_000, 1_700_000_000) : 0,
      age: dated && rand() < 0.9 ? randInt(1_400_000_000, 1_500_000_000) : 0,
      own: rand() < 0.95 ? SOURCES[randInt(0, SOURCES.length - 1)] : undefined,
      ownN: randInt(1, 9),
    });
  }
  return { ids, statsOf: (id) => meta.get(id) };
}

// --- Comparison -----------------------------------------------------------------

function compare(label, a, b) {
  let bad = null;
  for (let l = 0; l <= MAX_LEVEL && !bad; l++) {
    if (a.litSets[l].size !== b.litSets[l].size) {
      bad = `level ${l}: ${a.litSets[l].size} entries against ${b.litSets[l].size}`;
      break;
    }
    for (const [key, x] of a.litSets[l]) {
      const y = b.litSets[l].get(key);
      if (!y) {
        bad = `level ${l} ${key} missing`;
        break;
      }
      for (const f of ['hits', 'cells', 'time', 'age']) {
        if (x[f] !== y[f]) bad = `level ${l} ${key} ${f}: ${x[f]} against ${y[f]}`;
      }
      if (Math.abs(x.near - y.near) > 1e-12) bad = `level ${l} ${key} near: ${x.near} against ${y.near}`;
      if (dominantSource(x) !== dominantSource(y)) {
        bad = `level ${l} ${key} source: ${dominantSource(x)} against ${dominantSource(y)}`;
      }
      const under = storedUnder(b.litSets, l, key).sort().join();
      if ([...x.ids].sort().join() !== under) bad = `level ${l} ${key}: different stored ids under it`;
      if (bad) break;
    }
  }
  check(!bad, label, bad);
}

console.log('\nLevel by level comes out the same as the walk it replaced');
{
  const { ids, statsOf } = makeHistory(6000);
  const cases = [
    ['plain', {}],
    ['with the per-source tally', { byType: true }],
    ['with a source hidden', { hidden: new Set(['komoot']) }],
    ['with the tally and a source hidden', { byType: true, hidden: new Set(['strava', 'manual']) }],
  ];
  for (const [name, opts] of cases) {
    const old = rollUpOld(ids, statsOf, opts);
    const neu = rollUp(ids, statsOf, opts);
    attachNeighbourhoods(neu.litSets);
    compare(name, old, neu);
    const shownSame = old.shown === null
      ? neu.shown === null
      : [...old.shown].sort().join() === [...neu.shown].sort().join();
    check(shownSame, `${name}: the same stored cells are drawn`);
    const counts = (m) => [...m].sort().join();
    check(counts(old.sourceCells) === counts(neu.sourceCells), `${name}: the same count per source`);
  }
}

console.log('\nA brush, one cell at a time, lands where a rebuild would');
{
  const { ids, statsOf } = makeHistory(3000);
  const all = [...ids].filter((id) => parseCellId(id)[0] <= MAX_LEVEL);
  // Hand-painted cells are undated and single-visit; that is the only kind the
  // map folds in without a rebuild.
  const undated = (id) => ({ ...statsOf(id), time: 0, age: 0, hits: 1 });
  const base = all.slice(0, 2000);
  const painted = all.slice(2000);

  const live = rollUp(base, undated);
  const index = live.litSets.map((m) => indexCells(m));
  for (const id of painted) foldInCell(live.litSets, index, id, 1);
  attachNeighbourhoods(live.litSets);
  const fresh = rollUpOld(all, undated);
  compare('painting cells in one by one', fresh, live);

  // And back out again: every other painted cell, then a whole town's worth.
  const erased = new Set(painted.filter((_, i) => i % 2));
  for (const id of all.slice(0, 700)) erased.add(id);
  for (const id of erased) removeCell(live.litSets, index, id, 1);
  attachNeighbourhoods(live.litSets);
  const rest = all.filter((id) => !erased.has(id));
  const after = rollUpOld(rest, undated);
  compare('and erasing some of them again', after, live);

  // The index followed every add and every removal.
  let indexed = true;
  for (let l = 0; l <= MAX_LEVEL; l++) {
    if (index[l].size !== live.litSets[l].size) indexed = false;
  }
  check(indexed, 'the cell index kept pace with both');

  // Painting a cell back where one was erased must not name it twice.
  const again = [...erased][0];
  foldInCell(live.litSets, index, again, 1);
  const [L, c, r] = parseCellId(again);
  let key = `${c}/${r}`;
  let [col, row] = [c, r];
  let once = true;
  for (let l = L; l <= MAX_LEVEL; l++) {
    if (l > L) {
      [col, row] = parentOf(l - 1, col, row);
      key = `${col}/${row}`;
    }
    const n = storedUnder(live.litSets, l, key).filter((id) => id === again).length;
    if (n !== 1) once = false;
  }
  check(once, 'a cell painted where it was erased is under each ancestor once');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
