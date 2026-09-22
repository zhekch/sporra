// Pure geometry for the one-time refinement of the hex grid from ~0.9 km
// (equator) to ~74 m. The script in migrate-cell-size.mjs does the database
// and the network; everything here is deterministic so a test can hold it
// without either.
//
// The old lattice is inlined rather than imported. src/hexgrid.js is already
// the new one, and a cell id is only meaningful in the lattice that wrote it.

import {
  colsOf,
  latOf,
  lngOf,
  mercX,
  mercY,
  normCol,
  parseCellId,
  pointToCell,
  SQRT3,
  WORLD,
  wrapLng,
} from '../src/hexgrid.js';

/** Flat-to-flat spacing used when walking a line into cells. Under the
 *  inradius (~25 m), so a straight segment cannot step over a cell. */
export const SAMPLE_M = 15;

/** A snap farther than this is outside the old hex, not a correction of it. */
export const ACCEPT_M = 400;
export const ACCEPT_FRAC = 0.75;

/** A cell with this many marked neighbours is a patch of town, not a corridor. */
export const CITY_NEIGHBORS = 4;

/** On a long chain, a railway this close to the road's residual wins the tie.
 *  The usual shape is the road that runs beside the tracks. */
export const RAIL_TIE_M = 150;
export const RAIL_TIE_LENGTH_M = 20_000;

/** Faster than this, and with no railway that fits, the chain is not a road.
 *  Pulling a flight down onto a motorway is worse than leaving the old line. */
export const FLIGHT_MPS = 150 / 3.6;

const OLD_BASE_COLS = 642 * 81; // 52_002, the lattice these rows were written in
const OLD_R0 = (WORLD / OLD_BASE_COLS) / 1.5;

const R = 6378137;

export function haversine(a, b) {
  const p1 = (a[1] * Math.PI) / 180;
  const p2 = (b[1] * Math.PI) / 180;
  const dp = ((b[1] - a[1]) * Math.PI) / 180;
  let dl = ((b[0] - a[0]) * Math.PI) / 180;
  if (dl > Math.PI) dl -= 2 * Math.PI;
  if (dl < -Math.PI) dl += 2 * Math.PI;
  const h = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

function oldPointToCell(x, y) {
  const qf = ((2 / 3) * x) / OLD_R0;
  const rf = (-x / 3 + (SQRT3 / 3) * y) / OLD_R0;
  let q = Math.round(qf);
  let r = Math.round(rf);
  const s = Math.round(-qf - rf);
  const dq = Math.abs(q - qf);
  const dr = Math.abs(r - rf);
  const ds = Math.abs(s - (-qf - rf));
  if (dq > dr && dq > ds) q = -s - r;
  else if (dr > ds) r = -q - s;
  return [q, r + (q - (q & 1)) / 2];
}

function oldCenter(col, row) {
  return [1.5 * OLD_R0 * col, SQRT3 * OLD_R0 * (row + (col & 1 ? 0.5 : 0))];
}

/** "0/col/row" in the lattice that is in the database today. */
export function oldCellId(lng, lat) {
  const [col, row] = oldPointToCell(mercX(lng), mercY(lat));
  return `0/${normCol(col, OLD_BASE_COLS)}/${row}`;
}

/** "0/col/row" in the lattice the server is about to store. */
export function newCellId(lng, lat) {
  const [col, row] = pointToCell(0, mercX(lng), mercY(lat));
  return `0/${normCol(col, colsOf(0))}/${row}`;
}

/** Centre of a stored old id, as [lng, lat]. */
export function oldCenterLngLat(id) {
  const [L, col, row] = parseCellId(id);
  if (!(L === 0) || !Number.isFinite(col) || !Number.isFinite(row)) return null;
  const [x, y] = oldCenter(col, row);
  return [wrapLng(lngOf(x)), latOf(y)];
}

export function newCenterLngLat(id) {
  const [L, col, row] = parseCellId(id);
  if (!Number.isFinite(col) || !Number.isFinite(row)) return null;
  // The new radius, via the same formula hexgrid uses, so a centre we test
  // against oldCellId is the centre the map will draw.
  const radius = (WORLD / colsOf(0)) / 1.5 * 3 ** (L || 0);
  const x = 1.5 * radius * col;
  const y = SQRT3 * radius * (row + (col & 1 ? 0.5 : 0));
  return [wrapLng(lngOf(x)), latOf(y)];
}

function neighborsOf(col, row) {
  const p = col & 1;
  return [
    [col, row + 1],
    [col + 1, row + p],
    [col + 1, row + p - 1],
    [col, row - 1],
    [col - 1, row + p - 1],
    [col - 1, row + p],
  ];
}

function idAt(col, row) {
  return `0/${normCol(col, OLD_BASE_COLS)}/${row}`;
}

export function neighborIds(id) {
  const [L, col, row] = parseCellId(id);
  if (L !== 0 || !Number.isFinite(col)) return [];
  return neighborsOf(col, row).map(([c, r]) => idAt(c, r));
}

/**
 * Split a set of old level-0 ids into town patches, corridors and specks.
 *
 * A connected component is the wrong object: one life of travel is a single
 * component the size of a continent, because the corridors touch. A corridor
 * cell has two neighbours. A town cell has four or more — the disc is full,
 * not a line that happens to branch. What is left over, a cell with no
 * neighbour at all, is a speck.
 *
 * @param {Iterable<string>} ids
 * @returns {{ city: string[], chains: string[][], specks: string[] }}
 */
export function classify(ids) {
  const set = new Set(ids);
  const city = [];
  const rest = [];
  for (const id of set) {
    const n = neighborIds(id).reduce((k, nb) => k + (set.has(nb) ? 1 : 0), 0);
    if (n >= CITY_NEIGHBORS) city.push(id);
    else rest.push(id);
  }
  const restSet = new Set(rest);
  const nbrs = new Map();
  for (const id of rest) {
    nbrs.set(id, neighborIds(id).filter((nb) => restSet.has(nb)));
  }
  const deg = (id) => nbrs.get(id).length;
  const used = new Set();
  const edge = (a, b) => (a < b ? `${a}|${b}` : `${b}|${a}`);
  const chains = [];

  function walk(start, next) {
    const path = [start];
    const seen = new Set([start]);
    let prev = start;
    let cur = next;
    while (cur && deg(cur) === 2 && !seen.has(cur)) {
      path.push(cur);
      seen.add(cur);
      const ns = nbrs.get(cur);
      const nxt = ns[0] === prev ? ns[1] : ns[0];
      prev = cur;
      cur = nxt;
    }
    if (cur && cur !== path[path.length - 1]) path.push(cur);
    return path;
  }

  function take(path) {
    if (path.length < 2) return;
    for (let i = 1; i < path.length; i++) used.add(edge(path[i - 1], path[i]));
    const last = path[path.length - 1];
    if (path.length > 2 && deg(path[0]) === 2 && nbrs.get(last).includes(path[0])) {
      used.add(edge(last, path[0]));
    }
    chains.push(path);
  }

  for (const id of rest) {
    if (deg(id) === 2) continue;
    for (const n of nbrs.get(id)) {
      if (used.has(edge(id, n))) continue;
      take(walk(id, n));
    }
  }
  for (const id of rest) {
    if (deg(id) !== 2) continue;
    const n = nbrs.get(id)[0];
    if (used.has(edge(id, n))) continue;
    take(walk(id, n));
  }

  const chained = new Set(chains.flat());
  const specks = rest.filter((id) => !chained.has(id));
  return { city, chains, specks };
}

/** Old-cell centres, in chain order, dropping any id that does not parse. */
export function chainTrace(chain) {
  const out = [];
  for (const id of chain) {
    const c = oldCenterLngLat(id);
    if (c) out.push({ id, lng: c[0], lat: c[1] });
  }
  return out;
}

export function traceLength(trace) {
  let m = 0;
  for (let i = 1; i < trace.length; i++) {
    m += haversine([trace[i - 1].lng, trace[i - 1].lat], [trace[i].lng, trace[i].lat]);
  }
  return m;
}

/**
 * Metres per second along a trace, from the clocks on its two ends.
 * Null when either end has no clock — a hand-painted chain usually doesn't,
 * and a guess of "slow" would hide a flight that also doesn't.
 */
export function traceSpeed(trace) {
  const a = trace.find((p) => p.t > 0);
  const b = [...trace].reverse().find((p) => p.t > 0);
  if (!a || !b || a === b) return null;
  const dt = Math.abs(b.t - a.t);
  if (dt < 1) return null;
  return traceLength(trace) / dt;
}

function walkCoords(coords, stepM, visit) {
  if (!coords?.length) return;
  visit(coords[0][0], coords[0][1]);
  for (let i = 1; i < coords.length; i++) {
    const a = coords[i - 1];
    const b = coords[i];
    let dLng = b[0] - a[0];
    if (dLng > 180) dLng -= 360;
    else if (dLng < -180) dLng += 360;
    const d = haversine(a, [a[0] + dLng, b[1]]);
    const n = Math.max(1, Math.ceil(d / stepM));
    for (let s = 1; s <= n; s++) {
      const t = s / n;
      let lng = a[0] + dLng * t;
      if (lng > 180) lng -= 360;
      else if (lng < -180) lng += 360;
      visit(lng, a[1] + (b[1] - a[1]) * t);
    }
  }
}

/** New level-0 ids a polyline actually crosses, not just the ones its vertices sit in. */
export function rasterize(coords, stepM = SAMPLE_M) {
  const ids = new Set();
  walkCoords(coords, stepM, (lng, lat) => ids.add(newCellId(lng, lat)));
  return ids;
}

export function rasterizeSegments(segments, stepM = SAMPLE_M) {
  const ids = new Set();
  for (const seg of segments || []) {
    const coords = seg.map((p) => (Array.isArray(p) ? p : [p.lng, p.lat]));
    for (const id of rasterize(coords, stepM)) ids.add(id);
  }
  return ids;
}

/**
 * New cells whose sample falls inside one of `oldIds`.
 * How a street is clipped to the hexes that were actually marked.
 */
export function cellsInside(coords, oldIds, stepM = SAMPLE_M) {
  const want = oldIds instanceof Set ? oldIds : new Set(oldIds);
  const ids = new Set();
  walkCoords(coords, stepM, (lng, lat) => {
    if (want.has(oldCellId(lng, lat))) ids.add(newCellId(lng, lat));
  });
  return ids;
}

function closestOnSegment(lng, lat, a, b) {
  const lat0 = (((lat + a[1] + b[1]) / 3) * Math.PI) / 180;
  const kx = 111_320 * Math.cos(lat0);
  const ky = 110_540;
  const ax = a[0] * kx;
  const ay = a[1] * ky;
  const bx = b[0] * kx;
  const by = b[1] * ky;
  const px = lng * kx;
  const py = lat * ky;
  const dx = bx - ax;
  const dy = by - ay;
  const len2 = dx * dx + dy * dy;
  let t = len2 === 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / len2;
  if (t < 0) t = 0;
  else if (t > 1) t = 1;
  return { t, lng: (ax + dx * t) / kx, lat: (ay + dy * t) / ky };
}

function prepareWay(raw) {
  const coords = raw.coords;
  if (!coords || coords.length < 2) return null;
  const cum = [0];
  for (let i = 1; i < coords.length; i++) cum.push(cum[i - 1] + haversine(coords[i - 1], coords[i]));
  if (cum[cum.length - 1] < 5) return null;
  return { coords, cum, length: cum[cum.length - 1], kind: raw.kind };
}

const BUCKET = 0.02;

function bucketOf(lng, lat) {
  return `${Math.floor(lng / BUCKET)},${Math.floor(lat / BUCKET)}`;
}

/**
 * Snap an ordered trace to a network and return the polyline that follows it.
 *
 * The trace is a run of old cell centres, ~600 m apart, so this is a coarse
 * match rather than a GPS one. Candidates are the nearest ways within
 * `radiusM`. The sequence is chosen by a small Viterbi: staying on the way
 * you are on is cheap, hopping to a way that touches it is a little dearer,
 * and jumping to a disconnected way is expensive. The geometry between the
 * chosen snaps is the way itself, not the straight line, which is the whole
 * reason to match — a chord between centres cuts the corner of the block.
 *
 * Returns null when the network does not actually explain the trace. A match
 * that only wins by leaving the corridor is not a correction.
 */
export function matchTrace(trace, rawWays, { radiusM = 500 } = {}) {
  if (!trace?.length || !rawWays?.length) return null;
  const ways = [];
  for (const raw of rawWays) {
    const w = prepareWay(raw);
    if (w) ways.push(w);
  }
  if (!ways.length) return null;

  const buckets = new Map();
  const addSeg = (way, i) => {
    const a = ways[way].coords[i];
    const b = ways[way].coords[i + 1];
    // A highway vertex can sit kilometres from the next one. Bucketing only
    // the ends would hide the middle from a trace point standing on it.
    const steps = Math.max(1, Math.ceil(haversine(a, b) / (BUCKET * 80_000)));
    const seen = new Set();
    for (let s = 0; s <= steps; s++) {
      const t = s / steps;
      seen.add(bucketOf(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t));
    }
    for (const k of seen) {
      let list = buckets.get(k);
      if (!list) buckets.set(k, (list = []));
      list.push([way, i]);
    }
  };
  for (let w = 0; w < ways.length; w++) {
    for (let i = 1; i < ways[w].coords.length; i++) addSeg(w, i - 1);
  }

  const nodeWays = new Map();
  const nodeKey = (lng, lat) => `${lng.toFixed(5)},${lat.toFixed(5)}`;
  for (let w = 0; w < ways.length; w++) {
    for (const [lng, lat] of ways[w].coords) {
      const k = nodeKey(lng, lat);
      let list = nodeWays.get(k);
      if (!list) nodeWays.set(k, (list = []));
      list.push(w);
    }
  }
  const adj = new Map();
  const link = (a, b) => {
    if (a === b) return;
    let s = adj.get(a);
    if (!s) adj.set(a, (s = new Set()));
    s.add(b);
  };
  for (const group of nodeWays.values()) {
    for (let i = 0; i < group.length; i++) {
      for (let j = i + 1; j < group.length; j++) {
        link(group[i], group[j]);
        link(group[j], group[i]);
      }
    }
  }

  function candidatesAt(lng, lat) {
    const reach = Math.ceil(radiusM / 111_320 / BUCKET) + 1;
    const cx = Math.floor(lng / BUCKET);
    const cy = Math.floor(lat / BUCKET);
    const best = new Map();
    for (let dx = -reach; dx <= reach; dx++) {
      for (let dy = -reach; dy <= reach; dy++) {
        const list = buckets.get(`${cx + dx},${cy + dy}`);
        if (!list) continue;
        for (const [way, i] of list) {
          const w = ways[way];
          const proj = closestOnSegment(lng, lat, w.coords[i], w.coords[i + 1]);
          const dist = haversine([lng, lat], [proj.lng, proj.lat]);
          if (dist > radiusM) continue;
          const along = w.cum[i] + proj.t * (w.cum[i + 1] - w.cum[i]);
          const prev = best.get(way);
          if (!prev || dist < prev.dist) {
            best.set(way, { way, dist, along, lng: proj.lng, lat: proj.lat });
          }
        }
      }
    }
    return [...best.values()].sort((a, b) => a.dist - b.dist).slice(0, 6);
  }

  const cols = trace.map((p) => candidatesAt(p.lng, p.lat));
  const usable = cols.map((c, i) => (c.length ? i : -1)).filter((i) => i >= 0);
  if (!usable.length) return null;

  // cost[step][candidate] = best cost of reaching it, and which previous candidate
  const cost = [];
  const prev = [];
  for (let s = 0; s < usable.length; s++) {
    const i = usable[s];
    const col = cols[i];
    cost.push(new Float64Array(col.length));
    prev.push(new Int16Array(col.length).fill(-1));
    if (s === 0) {
      for (let k = 0; k < col.length; k++) cost[0][k] = (col[k].dist / 200) ** 2;
      continue;
    }
    const pi = usable[s - 1];
    const traceDist = haversine(
      [trace[pi].lng, trace[pi].lat],
      [trace[i].lng, trace[i].lat],
    );
    const pcol = cols[pi];
    for (let k = 0; k < col.length; k++) {
      let best = Infinity;
      let from = -1;
      for (let p = 0; p < pcol.length; p++) {
        const a = pcol[p];
        const b = col[k];
        let dNet;
        let extra = 0;
        if (a.way === b.way) dNet = Math.abs(b.along - a.along);
        else if (adj.get(a.way)?.has(b.way)) {
          dNet = haversine([a.lng, a.lat], [b.lng, b.lat]);
          extra = 40;
        } else {
          dNet = haversine([a.lng, a.lat], [b.lng, b.lat]);
          extra = 500;
        }
        const step = ((Math.abs(dNet - traceDist) + extra) / 200) ** 2 + (b.dist / 200) ** 2;
        const c = cost[s - 1][p] + step;
        if (c < best) {
          best = c;
          from = p;
        }
      }
      cost[s][k] = best;
      prev[s][k] = from;
    }
  }

  let last = 0;
  for (let k = 1; k < cols[usable[usable.length - 1]].length; k++) {
    if (cost[cost.length - 1][k] < cost[cost.length - 1][last]) last = k;
  }
  const chosen = new Array(usable.length);
  for (let s = usable.length - 1; s >= 0; s--) {
    chosen[s] = cols[usable[s]][last];
    last = prev[s][last];
  }

  let within = 0;
  let sum = 0;
  for (const c of chosen) {
    sum += c.dist;
    if (c.dist <= ACCEPT_M) within++;
  }
  const frac = within / trace.length;
  const meanM = sum / chosen.length;
  if (frac < ACCEPT_FRAC || meanM > ACCEPT_M) return null;

  const coords = stitch(chosen, ways, adj);
  if (!coords || coords.length < 1) return null;
  const got = polylineLength(coords);
  const want = traceLength(trace);
  // A path that wanders off to find a connection is not the chain we had.
  if (want > 1000 && got > want * 3 && got > want + 2000) return null;
  return { coords, meanM, frac, kind: ways[chosen[0].way].kind ?? null };
}

function polylineLength(coords) {
  let m = 0;
  for (let i = 1; i < coords.length; i++) m += haversine(coords[i - 1], coords[i]);
  return m;
}

function sliceWay(way, fromAlong, toAlong) {
  const lo = Math.min(fromAlong, toAlong);
  const hi = Math.max(fromAlong, toAlong);
  const forward = fromAlong <= toAlong;
  const pts = [];
  const push = (lng, lat) => {
    const last = pts[pts.length - 1];
    if (last && last[0] === lng && last[1] === lat) return;
    pts.push([lng, lat]);
  };
  // Point at a given along-track distance.
  const at = (dist) => {
    const c = way.cum;
    let i = 1;
    while (i < c.length - 1 && c[i] < dist) i++;
    const span = c[i] - c[i - 1] || 1;
    const t = Math.max(0, Math.min(1, (dist - c[i - 1]) / span));
    const a = way.coords[i - 1];
    const b = way.coords[i];
    return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
  };
  push(...at(lo));
  for (let i = 1; i < way.cum.length - 1; i++) {
    if (way.cum[i] > lo && way.cum[i] < hi) push(...way.coords[i]);
  }
  push(...at(hi));
  if (!forward) pts.reverse();
  return pts;
}

function append(out, pts) {
  for (const p of pts) {
    const last = out[out.length - 1];
    if (last && Math.abs(last[0] - p[0]) < 1e-7 && Math.abs(last[1] - p[1]) < 1e-7) continue;
    out.push(p);
  }
}

/** Which end of `way` the shared vertex with `other` sits at, as an along-distance. */
function sharedAlong(way, other) {
  const key = (p) => `${p[0].toFixed(5)},${p[1].toFixed(5)}`;
  const ends = new Map();
  for (const p of other.coords) ends.set(key(p), true);
  const a = way.coords[0];
  const b = way.coords[way.coords.length - 1];
  if (ends.has(key(a))) return 0;
  if (ends.has(key(b))) return way.length;
  // A touch in the middle: the vertex of `way` that the other way also has.
  for (let i = 0; i < way.coords.length; i++) {
    if (ends.has(key(way.coords[i]))) return way.cum[i];
  }
  return null;
}

function bfsWays(start, goal, adj, limit = 6) {
  if (start === goal) return [start];
  const q = [[start]];
  const seen = new Set([start]);
  while (q.length) {
    const path = q.shift();
    if (path.length > limit) continue;
    const last = path[path.length - 1];
    for (const n of adj.get(last) || []) {
      if (seen.has(n)) continue;
      const next = [...path, n];
      if (n === goal) return next;
      seen.add(n);
      q.push(next);
    }
  }
  return null;
}

function stitch(chosen, ways, adj) {
  const out = [];
  append(out, [[chosen[0].lng, chosen[0].lat]]);
  for (let i = 1; i < chosen.length; i++) {
    const a = chosen[i - 1];
    const b = chosen[i];
    if (a.way === b.way) {
      append(out, sliceWay(ways[a.way], a.along, b.along));
      continue;
    }
    const path = bfsWays(a.way, b.way, adj);
    if (!path || path.length < 2) {
      append(out, [[b.lng, b.lat]]);
      continue;
    }
    // Leave each way at the vertex it shares with the next, and arrive on the
    // last one at the snap. An intermediate way is walked in full; stopping
    // at the first hop would draw the junction and then a chord.
    let along = a.along;
    let ok = true;
    for (let p = 0; p < path.length && ok; p++) {
      const here = ways[path[p]];
      if (p === path.length - 1) {
        append(out, sliceWay(here, along, b.along));
        break;
      }
      const there = ways[path[p + 1]];
      const leave = sharedAlong(here, there);
      const enter = sharedAlong(there, here);
      if (leave == null || enter == null) ok = false;
      else {
        append(out, sliceWay(here, along, leave));
        along = enter;
      }
    }
    if (!ok) append(out, [[b.lng, b.lat]]);
  }
  return out;
}

/**
 * Road match, rail match, or neither.
 *
 * `road` and `rail` are what `matchTrace` returned (or null). A long chain
 * prefers the railway when the two are close, because that is the pair a
 * road beside a track always produces. Anything faster than traffic, with no
 * railway, is left unmatched so it is not dragged onto a motorway.
 */
export function chooseNetwork(road, rail, { lengthM = 0, speedMps = null } = {}) {
  const good = (m) => m && m.frac >= ACCEPT_FRAC && m.meanM <= ACCEPT_M;
  const railOk = good(rail);
  const roadOk = good(road);
  if (speedMps != null && speedMps > FLIGHT_MPS && !railOk) return null;
  if (railOk && roadOk) {
    if (lengthM >= RAIL_TIE_LENGTH_M && rail.meanM <= road.meanM + RAIL_TIE_M) return { ...rail, kind: 'rail' };
    return road.meanM <= rail.meanM ? { ...road, kind: 'road' } : { ...rail, kind: 'rail' };
  }
  if (railOk) return { ...rail, kind: 'rail' };
  if (roadOk) return { ...road, kind: 'road' };
  return null;
}
