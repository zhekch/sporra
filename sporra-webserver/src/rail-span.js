// The piece of railway a click paints.
//
// OpenRailwayMap's tiles draw the line and name the OSM way, and they stop
// there. A way is often a few dozen metres — split wherever the tags change,
// not only at a switch — so the piece under the pointer is not the run. The
// run is the connected track from the previous station or junction to the next
// one. A halt, a stop position, a signal, a switch that does not actually
// branch: none of those is an end. A second track running alongside is not
// an end either — the two red rails of a double line are one corridor, and
// the switch between them is not a choice of route. A junction is a line
// that leaves that corridor. With neither a station
// nor a junction in reach, the span is the straight track itself, not the one
// way the pointer happened to hit.

import { latOf, lngOf, mercX, mercY, WORLD } from './hexgrid.js';

// How far one query looks. The server asks again from an end that fell on the
// rim, so a station past this is still the end of the run.
export const RAIL_SPAN_RADIUS_M = 12000;

// A station this close along the track is the one you are standing in. Using
// it as both ends would paint nothing.
const STOP_GAP_M = 40;
// The station node is the building, beside the rail.
const STATION_M = 160;
// How far a second track may sit from the one you clicked and still be the
// same line. A branch has left the corridor by the end of this look-ahead; a
// track running alongside has not.
const CORRIDOR_M = 45;
const LOOK_M = 220;

/**
 * A station, or null.
 *
 * Halts and stop positions sit on the same straight track every few minutes
 * of running. Ending the run at one of them is why a click landed in the
 * middle of a line that had not branched and had not reached a station.
 *
 * @param {object} [tags]
 * @returns {'station'|null}
 */
export function stopKind(tags) {
  if (!tags) return null;
  return tags.railway === 'station' ? 'station' : null;
}

/**
 * The Overpass query for one click, or null when the arguments are not a way
 * and a place.
 *
 * The way is asked for by id as well as by the circle around the click: a
 * siding is filtered out of the circle, and it is still the thing that was
 * clicked.
 *
 * @param {string|number} wayId
 * @param {number} lng
 * @param {number} lat
 * @returns {string|null}
 */
export function railSpanQuery(wayId, lng, lat) {
  if (!/^\d{1,12}$/.test(String(wayId))) return null;
  if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;
  if (Math.abs(lat) > 85 || Math.abs(lng) > 180) return null;
  const r = RAIL_SPAN_RADIUS_M;
  const la = lat.toFixed(6);
  const ln = lng.toFixed(6);
  return `[out:json][timeout:25];
way(${wayId})->.hit;
(
  way.hit;
  way(around:${r},${la},${ln})[railway~"^(rail|light_rail|subway|tram|narrow_gauge|preserved|monorail)$"];
  node(around:${r},${la},${ln})[railway=station];
);
out geom;`;
}

/**
 * Ways and stops out of an Overpass answer.
 *
 * @param {object[]} elements
 */
export function waysAndStops(elements) {
  const ways = [];
  const stops = [];
  for (const el of elements || []) {
    if (el.type === 'way') {
      const g = el.geometry;
      if (!g || g.length < 2) continue;
      const tags = el.tags || {};
      ways.push({
        id: el.id,
        points: g.map((p) => [p.lon, p.lat]),
        railway: tags.railway || '',
        service: tags.service || '',
        ref: tags.ref || '',
      });
    } else if (el.type === 'node' && Number.isFinite(el.lat) && Number.isFinite(el.lon)) {
      const kind = stopKind(el.tags);
      if (!kind) continue;
      const tags = el.tags || {};
      stops.push({
        lng: el.lon,
        lat: el.lat,
        name: tags.name || tags['name:en'] || '',
        kind,
      });
    }
  }
  return { ways, stops };
}

// Two metres. A shared node is the same coordinate; a way split by a tag
// change still meets. Parallel tracks sit further apart than this, so they
// do not become a junction by rounding.
const endKey = (xy) => `${Math.round(xy[0] / 2)}|${Math.round(xy[1] / 2)}`;

function gap(a, b) {
  let dx = b[0] - a[0];
  if (dx > WORLD / 2) dx -= WORLD;
  else if (dx < -WORLD / 2) dx += WORLD;
  return Math.hypot(dx, b[1] - a[1]);
}

function projectSeg(p, a, b) {
  const abx = b[0] - a[0];
  const aby = b[1] - a[1];
  const len2 = abx * abx + aby * aby;
  if (len2 < 1e-6) return { t: 0, d: gap(p, a), at: a };
  const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * abx + (p[1] - a[1]) * aby) / len2));
  const at = [a[0] + abx * t, a[1] + aby * t];
  return { t, d: gap(p, at), at };
}

function pointAt(way, along) {
  const target = Math.max(0, Math.min(way.total, along));
  for (let i = 1; i < way.xy.length; i++) {
    if (way.cum[i] + 1e-6 >= target) {
      const span = way.cum[i] - way.cum[i - 1];
      const t = span > 0 ? (target - way.cum[i - 1]) / span : 0;
      const a = way.xy[i - 1];
      const b = way.xy[i];
      return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
    }
  }
  return way.xy[way.xy.length - 1];
}

function sliceBetween(way, from, to) {
  const rev = to < from;
  const lo = Math.min(from, to);
  const hi = Math.max(from, to);
  const pts = [pointAt(way, lo)];
  for (let i = 1; i < way.xy.length - 1; i++) {
    if (way.cum[i] > lo + 0.05 && way.cum[i] < hi - 0.05) pts.push(way.xy[i]);
  }
  const end = pointAt(way, hi);
  if (gap(pts[pts.length - 1], end) > 0.05) pts.push(end);
  return rev ? pts.reverse() : pts;
}

function prepare(raw) {
  const seen = new Set();
  const ways = [];
  for (const w of raw) {
    if (!w || seen.has(w.id) || !w.points || w.points.length < 2) continue;
    seen.add(w.id);
    const xy = w.points.map(([lng, lat]) => [mercX(lng), mercY(lat)]);
    for (let i = 1; i < xy.length; i++) {
      const dx = xy[i][0] - xy[i - 1][0];
      if (dx > WORLD / 2) xy[i][0] -= WORLD;
      else if (dx < -WORLD / 2) xy[i][0] += WORLD;
    }
    const cum = [0];
    for (let i = 1; i < xy.length; i++) cum.push(cum[i - 1] + gap(xy[i - 1], xy[i]));
    const total = cum[cum.length - 1];
    if (!(total > 0.5)) continue;
    ways.push({
      id: w.id,
      service: w.service || '',
      railway: w.railway || '',
      ref: w.ref || '',
      xy,
      cum,
      total,
    });
  }
  const adj = new Map();
  const add = (key, rec) => {
    const arr = adj.get(key);
    if (arr) arr.push(rec);
    else adj.set(key, [rec]);
  };
  ways.forEach((w, wi) => {
    add(endKey(w.xy[0]), { wi, enterEnd: 0 });
    add(endKey(w.xy[w.xy.length - 1]), { wi, enterEnd: 1 });
  });
  return { ways, adj };
}

function locate(way, xy) {
  let bestD = Infinity;
  let along = 0;
  for (let i = 1; i < way.xy.length; i++) {
    const proj = projectSeg(xy, way.xy[i - 1], way.xy[i]);
    if (proj.d < bestD) {
      bestD = proj.d;
      along = way.cum[i - 1] + proj.t * (way.cum[i] - way.cum[i - 1]);
    }
  }
  return { d: bestD, along };
}

function continuations(ways, adj, wi, end, seen) {
  const way = ways[wi];
  const vertex = end === 0 ? way.xy[0] : way.xy[way.xy.length - 1];
  const byWay = new Map();
  for (const c of adj.get(endKey(vertex)) || []) {
    if (c.wi === wi || seen.has(c.wi) || byWay.has(c.wi)) continue;
    byWay.set(c.wi, c);
  }
  return [...byWay.values()];
}

function unitOf(a, b) {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len = Math.hypot(dx, dy) || 1;
  return [dx / len, dy / len];
}

function leaveDir(ways, cand) {
  const way = ways[cand.wi];
  const reach = Math.min(60, way.total);
  if (cand.enterEnd === 0) return unitOf(pointAt(way, 0), pointAt(way, reach));
  return unitOf(pointAt(way, way.total), pointAt(way, Math.max(0, way.total - reach)));
}

function incomingDir(ways, wi, end) {
  const way = ways[wi];
  const reach = Math.min(80, way.total);
  if (end === 1) return unitOf(pointAt(way, Math.max(0, way.total - reach)), pointAt(way, way.total));
  return unitOf(pointAt(way, Math.min(way.total, reach)), pointAt(way, 0));
}

// A point `metres` along this continuation. A short switch is followed onto
// whichever track it joins that still heads the same way, so a parallel line
// is measured out in the open and not on the slant of the points.
function aheadPoint(ways, adj, cand, dir, seen, metres) {
  let wi = cand.wi;
  let along = cand.enterEnd === 0 ? 0 : ways[wi].total;
  let d = cand.enterEnd === 0 ? 1 : -1;
  let travelled = 0;
  const local = new Set(seen);
  local.add(wi);
  let xy = cand.enterEnd === 0 ? ways[wi].xy[0] : ways[wi].xy[ways[wi].xy.length - 1];
  for (let hops = 0; hops < 24 && travelled < metres; hops++) {
    const way = ways[wi];
    const dest = d > 0 ? way.total : 0;
    const dist = Math.abs(dest - along);
    const remain = metres - travelled;
    if (dist >= remain - 0.01) {
      return pointAt(way, d > 0 ? along + remain : along - remain);
    }
    travelled += dist;
    xy = d > 0 ? way.xy[way.xy.length - 1] : way.xy[0];
    const end = d > 0 ? 1 : 0;
    const next = continuations(ways, adj, wi, end, local);
    if (!next.length) return xy;
    let best = next[0];
    let bestDot = -Infinity;
    for (const n of next) {
      const leave = leaveDir(ways, n);
      const dot = leave[0] * dir[0] + leave[1] * dir[1];
      if (dot > bestDot) {
        bestDot = dot;
        best = n;
      }
    }
    local.add(best.wi);
    wi = best.wi;
    if (best.enterEnd === 0) {
      along = 0;
      d = 1;
    } else {
      along = ways[wi].total;
      d = -1;
    }
  }
  return xy;
}

// The continuation that keeps this track. Other tracks running beside it are
// not a choice of route. A line that has left the corridor is.
function throughTrack(ways, adj, wi, end, next, seen) {
  const origin = end === 0 ? ways[wi].xy[0] : ways[wi].xy[ways[wi].xy.length - 1];
  const dir = incomingDir(ways, wi, end);
  const ranked = next.map((c) => {
    const leave = leaveDir(ways, c);
    return {
      c,
      dot: leave[0] * dir[0] + leave[1] * dir[1],
      far: aheadPoint(ways, adj, c, dir, seen, LOOK_M),
    };
  });
  ranked.sort((a, b) => b.dot - a.dot);
  const ref = ranked[0];
  const refDir = unitOf(origin, ref.far);
  const leaves = ranked.slice(1).some((s) => {
    const dx = s.far[0] - origin[0];
    const dy = s.far[1] - origin[1];
    const lat = Math.abs(dx * refDir[1] - dy * refDir[0]);
    return lat > CORRIDOR_M;
  });
  return leaves ? null : ref.c;
}

function walkDir(ways, adj, startWi, startAlong, dir, maxMetres) {
  const out = [];
  let travelled = 0;
  let why = 'end';
  const seen = new Set();
  let wi = startWi;
  let along = startAlong;
  let d = dir;
  for (let hops = 0; hops < 800 && travelled < maxMetres; hops++) {
    const way = ways[wi];
    seen.add(wi);
    const piece = sliceBetween(way, along, d > 0 ? way.total : 0);
    for (const xy of piece) {
      if (!out.length) {
        out.push({ xy, chain: 0 });
        continue;
      }
      const step = gap(out[out.length - 1].xy, xy);
      if (step < 0.05) continue;
      travelled += step;
      out.push({ xy, chain: travelled });
      if (travelled >= maxMetres) return { pts: out, why: 'limit' };
    }
    const end = d > 0 ? 1 : 0;
    const next = continuations(ways, adj, wi, end, seen);
    if (next.length === 0) break;
    // Two ways leaving is only a junction when one of them actually departs.
    // A second track beside this one, and the switch that joins them, stay
    // in the corridor — the run follows the track it arrived on.
    const chosen = next.length === 1 ? next[0] : throughTrack(ways, adj, wi, end, next, seen);
    if (!chosen) {
      why = 'junction';
      break;
    }
    wi = chosen.wi;
    if (chosen.enterEnd === 0) {
      along = 0;
      d = 1;
    } else {
      along = ways[wi].total;
      d = -1;
    }
  }
  return { pts: out, why };
}

function snapStations(line, stops) {
  const snapped = [];
  for (const stop of stops || []) {
    if (stop.kind !== 'station') continue;
    const xy = [mercX(stop.lng), mercY(stop.lat)];
    let best = null;
    for (let i = 1; i < line.length; i++) {
      const a = line[i - 1];
      const b = line[i];
      const proj = projectSeg(xy, a.xy, b.xy);
      if (proj.d > STATION_M) continue;
      const chain = a.chain + proj.t * (b.chain - a.chain);
      if (!best || proj.d < best.d) best = { d: proj.d, chain, name: stop.name || '' };
    }
    if (best) snapped.push(best);
  }
  return snapped;
}

function pointOnLine(line, chain) {
  if (chain <= line[0].chain) return line[0].xy;
  for (let i = 1; i < line.length; i++) {
    const a = line[i - 1];
    const b = line[i];
    if (b.chain + 1e-6 >= chain) return lerp(a, b, chain);
  }
  return line[line.length - 1].xy;
}

function endInfo(line, chain, why, name) {
  const xy = pointOnLine(line, chain);
  return {
    lng: lngOf(xy[0]),
    lat: latOf(xy[1]),
    why: name ? 'station' : why,
    name: name || null,
  };
}

function lerp(a, b, chain) {
  const span = b.chain - a.chain;
  const t = span !== 0 ? (chain - a.chain) / span : 0;
  return [a.xy[0] + (b.xy[0] - a.xy[0]) * t, a.xy[1] + (b.xy[1] - a.xy[1]) * t];
}

function cut(line, lo, hi) {
  const pts = [];
  const push = (xy) => {
    const last = pts[pts.length - 1];
    if (!last || gap(last, xy) > 0.4) pts.push(xy);
  };
  for (let i = 1; i < line.length; i++) {
    const a = line[i - 1];
    const b = line[i];
    if (b.chain < lo || a.chain > hi) continue;
    if (a.chain < lo && b.chain >= lo) push(lerp(a, b, lo));
    if (a.chain >= lo && a.chain <= hi) push(a.xy);
    if (b.chain >= lo && b.chain <= hi && (i === line.length - 1 || line[i + 1]?.chain > hi)) push(b.xy);
    if (a.chain <= hi && b.chain > hi) push(lerp(a, b, hi));
  }
  return pts;
}

/**
 * The run from the previous station or junction to the next one.
 *
 * `back` and `fore` say why each end stopped. `end` near the rim of a query
 * is the track leaving the area that was fetched, which is not a place the
 * run is finished.
 *
 * @param {object} o
 * @param {object[]} o.ways `{id, points:[[lng,lat]], railway, service, ref}`
 * @param {object[]} o.stops `{lng, lat, name, kind}`
 * @param {number} o.wayId the way that was clicked
 * @param {number} o.lng
 * @param {number} o.lat
 * @param {number} [o.maxMetres]
 * @returns {{points: number[][], from: string|null, to: string|null, back: object, fore: object}|null}
 */
export function spanBetweenStops({ ways: raw, stops, wayId, lng, lat, maxMetres = 40000 }) {
  const { ways, adj } = prepare(raw);
  const seed = ways.findIndex((w) => w.id === wayId || String(w.id) === String(wayId));
  if (seed < 0) return null;
  const here = locate(ways[seed], [mercX(lng), mercY(lat)]);
  const back = walkDir(ways, adj, seed, here.along, -1, maxMetres);
  const fore = walkDir(ways, adj, seed, here.along, 1, maxMetres);
  const line = [];
  for (let i = back.pts.length - 1; i >= 1; i--) line.push({ xy: back.pts[i].xy, chain: -back.pts[i].chain });
  for (const p of fore.pts) line.push(p);
  if (line.length < 2) return null;

  const kept = snapStations(line, stops);
  const behind = kept.filter((s) => s.chain <= -STOP_GAP_M);
  const ahead = kept.filter((s) => s.chain >= STOP_GAP_M);
  // No station in a direction means the whole walked track — the join where
  // one OSM way ends and the next begins is not an end. Cutting back to the
  // way under the pointer is what left a few dozen metres lit in the middle
  // of a straight line.
  const lo = behind.length ? Math.max(...behind.map((s) => s.chain)) : line[0].chain;
  const hi = ahead.length ? Math.min(...ahead.map((s) => s.chain)) : line[line.length - 1].chain;
  if (!(hi > lo + 0.5)) return null;
  const pts = cut(line, lo, hi);
  if (pts.length < 2) return null;
  const nameAt = (chain) => kept.find((s) => Math.abs(s.chain - chain) < 1)?.name || null;
  const fromName = behind.length ? nameAt(lo) : null;
  const toName = ahead.length ? nameAt(hi) : null;
  return {
    points: pts.map(([x, y]) => [lngOf(x), latOf(y)]),
    from: fromName,
    to: toName,
    back: endInfo(line, lo, back.why, fromName),
    fore: endInfo(line, hi, fore.why, toName),
  };
}
