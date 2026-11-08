// Rolling the stored cells up through the levels above them.
//
// `litSets[L]` maps "col/row" → the rolled-up stats of every cell lit at level
// L: each stored cell plus all of its ancestors, so colouring a small hexagon
// colours the big ones around it. What each entry holds:
//
//   hits   separate stays under it (see VISIT_GAP_SEC in locations.js)
//   time   most recent evidence (falls back to when it was added)
//   age    earliest evidence, 0 when nothing under it is dated
//   cells  stored cells under it
//   near   how busy its neighbourhood is — see neighbourhoodOf
//   src    palette slot of the source that saw it most (Type mode only)
//   col, row, parent, kids, ids — the lattice, kept so nothing below has to
//          parse a key again: where it is, the entry above it, the keys of the
//          entries below it, and the ids stored at exactly this cell.
//
// **Level by level, not cell by cell.** This used to walk every stored cell up
// all seven levels, building a string key and pushing the cell's id onto an
// array at each: on a map of half a million cells that is three and a half
// million lookups and three and a half million array slots, every sign-in and
// every change of colouring, and it was most of what a phone spent before the
// map could be touched. Each level is now built from the one below it instead —
// the ~700k entries of all levels, visited once each — and an entry names its
// children rather than carrying a copy of every id beneath it. `storedUnder`
// walks those names back down when somebody actually asks, which is a tap.
//
// The arithmetic is the same either way — sums, a maximum, a minimum over the
// dated, a tally — and scripts/test/rollup.mjs holds it to the old walk.

import { MAX_LEVEL, parentOf, parseCellId } from './hexgrid.js';
import { HEAT_NEIGHBOURHOOD, TYPE_MAX, hotOf, ageStopsOf } from './coloring.js';

const entry = (col, row, hits, time, age, cells, ids) => ({
  hits,
  time,
  age,
  cells,
  ids,
  col,
  row,
  parent: null,
  kids: null,
});

/**
 * Tally one source's visits onto a rolled-up cell. Nearly every cell only ever
 * sees a single source, so the Map is only allocated once a second turns up.
 */
export function addSource(e, src, hits) {
  if (e.srcMap) {
    e.srcMap.set(src, (e.srcMap.get(src) ?? 0) + hits);
  } else if (e.src1 === undefined) {
    e.src1 = src;
    e.n1 = hits;
  } else if (e.src1 === src) {
    e.n1 += hits;
  } else {
    e.srcMap = new Map([[e.src1, e.n1], [src, hits]]);
  }
}

// A child's whole tally, onto its parent.
function mergeSources(p, c) {
  if (c.srcMap) {
    for (const [src, n] of c.srcMap) addSource(p, src, n);
  } else if (c.src1 !== undefined) {
    addSource(p, c.src1, c.n1);
  }
}

/**
 * Which source speaks for this cell: the one that saw you there most often.
 * Ties go to the alphabetically first, so the map doesn't shuffle between loads.
 */
export function dominantSource(e) {
  if (!e.srcMap) return e.src1;
  let best;
  let bestN = -1;
  for (const [src, n] of e.srcMap) {
    if (n > bestN || (n === bestN && src < best)) {
      best = src;
      bestN = n;
    }
  }
  return best;
}

/**
 * Roll every stored cell up through the levels above it.
 *
 * @param {Iterable<string>} visited  stored cell ids
 * @param {(id:string, withSource:boolean) => {hits:number, time:number,
 *   age:number, own?:string, ownN?:number}} statsOf  one stored cell's
 *   contribution — see cellStats in src/coloring.js
 * @param {object} [o]
 * @param {boolean} [o.byType]  also tally which source saw each cell most
 * @param {Set<string>} [o.hidden]  sources whose cells are not drawn
 * @returns {{litSets: Map[], sourceCells: Map<string, number>, shown: Set|null}}
 *   `sourceCells` counts stored cells per dominant source, hidden ones
 *   included (the palette is handed out in that order); `shown` is the stored
 *   ids actually drawn, or null when nothing is hidden and that is all of them.
 */
export function rollUp(visited, statsOf, opts) {
  return drain(rollUpSteps(visited, statsOf, opts));
}

// Run a step generator to the end, synchronously.
function drain(gen) {
  for (;;) {
    const step = gen.next();
    if (step.done) return step.value;
  }
}

// How many entries between the points where a sliced run may stop. Checking the
// clock is not free; a few thousand entries is well under a millisecond.
const STEP = 2048;

/**
 * `rollUp`, as a generator that yields every few thousand entries — for a caller
 * that wants to give the browser frames while it runs (src/cells-load.js,
 * `runSliced`). Nothing it builds is visible until it returns: the levels are
 * its own until then, so stopping between two yields leaves no half-rolled map
 * behind.
 */
export function* rollUpSteps(visited, statsOf, { byType = false, hidden = new Set() } = {}) {
  let k = 0;
  const litSets = Array.from({ length: MAX_LEVEL + 1 }, () => new Map());
  const sourceCells = new Map();
  const filtering = hidden.size > 0;
  const shown = filtering ? new Set() : null;

  // Every stored cell onto the level it was stored at.
  for (const id of visited) {
    const [L, col, row] = parseCellId(id);
    // Stored at a level that no longer exists. It draws no hexagon, but it is
    // not *hidden* either — it still lights the country it is in. Written as
    // the negation so an id that did not parse (NaN) lands here as well.
    if (!(L <= MAX_LEVEL)) {
      shown?.add(id);
      continue;
    }
    const { hits, time, age, own, ownN } = statsOf(id, byType || filtering);
    // Tallied before it is skipped: the palette is handed out in this order,
    // and counting only what is drawn would reshuffle every other source's
    // colour whenever one was switched off.
    if (byType && own) sourceCells.set(own, (sourceCells.get(own) ?? 0) + 1);
    if (filtering && hidden.has(own)) continue;
    shown?.add(id);

    const key = `${col}/${row}`;
    let e = litSets[L].get(key);
    if (e) {
      e.hits += hits;
      e.cells++;
      e.ids.push(id);
      if (time > e.time) e.time = time;
      if (age && (!e.age || age < e.age)) e.age = age;
    } else {
      litSets[L].set(key, (e = entry(col, row, hits, time, age, 1, [id])));
    }
    if (byType && own) addSource(e, own, ownN);
    if (++k % STEP === 0) yield;
  }

  // Then each level from the one below it. A level can also hold cells stored
  // there directly, which is why this merges into an existing entry rather
  // than assuming it builds each one.
  for (let l = 0; l < MAX_LEVEL; l++) {
    const up = litSets[l + 1];
    for (const [key, c] of litSets[l]) {
      const [pc, pr] = parentOf(l, c.col, c.row);
      const pk = `${pc}/${pr}`;
      let p = up.get(pk);
      if (p) {
        p.hits += c.hits;
        p.cells += c.cells;
        if (c.time > p.time) p.time = c.time;
        if (c.age && (!p.age || c.age < p.age)) p.age = c.age;
      } else {
        up.set(pk, (p = entry(pc, pr, c.hits, c.time, c.age, c.cells, [])));
      }
      (p.kids ??= []).push(key);
      c.parent = p;
      if (byType) mergeSources(p, c);
      if (++k % STEP === 0) yield;
    }
  }

  return { litSets, sourceCells, shown };
}

/**
 * How busy the area around one rolled-up cell is: arrivals per cell across the
 * hex `HEAT_NEIGHBOURHOOD` levels above it. Read beside the cell's own count so
 * that being seen once in the middle of a city and being seen once on a
 * motorway are not the same answer.
 *
 * Falls back to the cell's own density at the coarsest level, where there is
 * nothing further out to ask. Follows `parent` rather than re-deriving a key:
 * an entry's ancestors are lit by construction, so the chain never breaks.
 */
export function neighbourhoodOf(level, e) {
  const up = Math.min(MAX_LEVEL, level + HEAT_NEIGHBOURHOOD);
  const own = (x) => (x ? x.hits / x.cells : 0);
  let a = e;
  for (let l = level; l < up && a; l++) a = a.parent;
  return own(a) || own(e);
}

/** Fill in `near` on every entry of every level. */
export function attachNeighbourhoods(litSets) {
  drain(attachNeighbourhoodsSteps(litSets));
}

/** The same, yielding every few thousand entries. */
export function* attachNeighbourhoodsSteps(litSets) {
  let k = 0;
  for (let l = 0; l < litSets.length; l++) {
    for (const e of litSets[l].values()) {
      e.near = neighbourhoodOf(l, e);
      if (++k % STEP === 0) yield;
    }
  }
}

/**
 * Every stored cell that sits inside (or is) the cell at `key` on level `L`.
 * A fresh array, so a caller may clear what it names while walking it.
 */
export function storedUnder(litSets, L, key) {
  const top = litSets[L]?.get(key);
  if (!top) return [];
  const out = [];
  const walk = (l, e) => {
    for (const id of e.ids) out.push(id);
    if (!e.kids || l === 0) return;
    for (const k of e.kids) {
      const c = litSets[l - 1].get(k);
      if (c) walk(l - 1, c);
    }
  };
  walk(L, top);
  return out;
}

/**
 * Fold one newly stored, undated cell into an existing roll-up.
 *
 * Only for what a brush lays down: no dates, and no source tally. Anything else
 * changes the ranges the heat maps are drawn against, and the caller rebuilds.
 *
 * @param {object[]} [litIndex]  src/cell-index.js per level, where built
 * @returns {Array<[number, object]>} each level and the entry it touched,
 *   bottom first
 */
export function foldInCell(litSets, litIndex, id, hits) {
  let [L, col, row] = parseCellId(id);
  const touched = [];
  let child = null;
  let childKey = null;
  let childNew = false;
  for (let l = L; l <= MAX_LEVEL; l++) {
    if (l > L) [col, row] = parentOf(l - 1, col, row);
    const key = `${col}/${row}`;
    let e = litSets[l].get(key);
    const created = !e;
    if (e) {
      e.hits += hits;
      e.cells++;
    } else {
      litSets[l].set(key, (e = entry(col, row, hits, 0, 0, 1, [])));
      litIndex?.[l]?.add(key, col, row);
    }
    if (l === L) e.ids.push(id);
    if (child) {
      child.parent = e;
      if (childNew) (e.kids ??= []).push(childKey);
    }
    touched.push([l, e]);
    child = e;
    childKey = key;
    childNew = created;
  }
  return touched;
}

/**
 * Take one stored cell back out of a roll-up: its visits off every ancestor,
 * and any entry it was the last cell of, gone.
 *
 * Membership and counts compose backwards; dates do not, and are left for the
 * gesture's closing rebuild. The ids do now — an entry only carries the ids
 * stored at exactly its own cell, so taking one out is a splice of a list that
 * is nearly always one long, and a parent forgets a child it no longer has.
 */
export function removeCell(litSets, litIndex, id, hits) {
  let [L, col, row] = parseCellId(id);
  let goneKey = null;
  for (let l = L; l <= MAX_LEVEL; l++) {
    if (l > L) [col, row] = parentOf(l - 1, col, row);
    const key = `${col}/${row}`;
    const e = litSets[l].get(key);
    if (!e) {
      goneKey = null;
      continue;
    }
    if (goneKey !== null && e.kids) {
      const i = e.kids.indexOf(goneKey);
      if (i >= 0) e.kids.splice(i, 1);
    }
    if (l === L) {
      const i = e.ids.indexOf(id);
      if (i >= 0) e.ids.splice(i, 1);
    }
    e.cells -= 1;
    e.hits -= hits;
    if (e.cells <= 0) {
      litSets[l].delete(key);
      litIndex?.[l]?.remove(key, col, row);
      goneKey = key;
    } else {
      goneKey = null;
    }
  }
}

// Shared preparation keeps the browser and native render API on the same scales.
export function* finishRollUpSteps(rolled, byType) {
  const { litSets: sets, sourceCells } = rolled;
  let order = [];
  if (byType) {
    // Hand out palette slots by how much of the map each source accounts for.
    order = [...sourceCells.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .map(([src]) => src);
    const slot = new Map(order.map((src, i) => [src, i]));
    let k = 0;
    for (const lit of sets) {
      for (const e of lit.values()) {
        e.src = slot.get(dominantSource(e)) ?? TYPE_MAX;
        // The tally has done its job; drop it so the entries stay small.
        delete e.srcMap;
        delete e.src1;
        delete e.n1;
        if (++k % 4096 === 0) yield;
      }
    }
  }
  rolled.sourceOrder = order;

  yield* attachNeighbourhoodsSteps(sets);

  rolled.litRange = [];
  for (const lit of sets) {
    const r = { maxHits: 1, hotHits: 2, minTime: 0, maxTime: 0, minAge: 0, maxAge: 0 };
    r.hotHits = hotOf(lit);
    // What the dates on this level actually look like, for the same reason
    // `hotHits` exists: the ends of the range do not describe the middle.
    r.ageStops = ageStopsOf(lit);
    for (const e of lit.values()) {
      if (e.hits > r.maxHits) r.maxHits = e.hits;
      if (e.time) {
        if (!r.minTime || e.time < r.minTime) r.minTime = e.time;
        if (e.time > r.maxTime) r.maxTime = e.time;
      }
      if (e.age) {
        if (!r.minAge || e.age < r.minAge) r.minAge = e.age;
        if (e.age > r.maxAge) r.maxAge = e.age;
      }
    }
    rolled.litRange.push(r);
    yield;
  }
  return true;
}
