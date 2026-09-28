// The piece of railway a click paints: from the stop before the pointer to the
// stop after it.
//
// OpenRailwayMap's tiles draw the line and name the OSM way, and they stop
// there. A way is often a few dozen metres — split at every switch — and a tile
// clips even that. The stops are other elements. So the span is worked out from
// the ways and the stops, not from the feature that was clicked.
//
// The walk stays on the running line. At a junction the straightest plain
// continuation wins, and a siding is not a continuation of a main line: taking
// it would paint the yard. A click that *was* on a siding stays on sidings.
// With no stop in a direction, the span ends where the clicked way ends rather
// than running on to the edge of the search.

import { latOf, lngOf, mercX, mercY, WORLD } from './hexgrid.js';

// How far around the click the ways and stops are asked for. A stop further
// than this is not the next one — the span ends at the clicked way instead.
export const RAIL_SPAN_RADIUS_M = 8000;

// A stop this close to the click is the place you are standing, not the end of
// the run. Counting it would make a tap in a station paint nothing.
const STOP_GAP_M = 12;
// stop_position nodes sit on the rail. A station node is the building, which
// is beside it. Anything further is a different line.
const POSITION_M = 18;
const STATION_M = 90;
// A station and the stop_position in front of it are one stop. The one on the
// rail is the end of the run.
const SAME_STOP_M = 250;

/**
 * Which kind of stop a node's tags are, or null.
 *
 * A `stop_position` with no railway tag is usually a bus. Snapping those onto
 * the track would end a line at a stop the train does not call at.
 *
 * @param {object} [tags]
 * @returns {'position'|'station'|null}
 */
export function stopKind(tags) {
  if (!tags) return null;
  const rw = tags.railway;
  if (rw === 'station' || rw === 'halt') return 'station';
  if (rw === 'tram_stop' || rw === 'stop') return 'position';
  if (tags.public_transport === 'stop_position'
    && (rw || tags.train === 'yes' || tags.tram === 'yes' || tags.subway === 'yes' || tags.light_rail === 'yes')) {
    return 'position';
  }
  return null;
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
  node(around:${r},${la},${ln})[railway~"^(station|halt|stop|tram_stop)$"];
  node(around:${r},${la},${ln})[public_transport=stop_position];
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

const endKey = (xy) => `${Math.round(xy[0] * 2) / 2}|${Math.round(xy[1] * 2) / 2}`;

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

function unitBetween(way, fromAlong, toAlong) {
  const a = pointAt(way, fromAlong);
  const b = pointAt(way, toAlong);
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len = Math.hypot(dx, dy) || 1;
  return [dx / len, dy / len];
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

function chooseNext(ways, adj, wi, end, seen) {
  const way = ways[wi];
  const vertex = end === 0 ? way.xy[0] : way.xy[way.xy.length - 1];
  let cands = (adj.get(endKey(vertex)) || []).filter((c) => c.wi !== wi && !seen.has(c.wi));
  if (!cands.length) return null;
  // A main line that only continues as a siding has ended. Following the siding
  // paints the yard. A click that started on a siding may keep to them.
  if (!way.service) {
    const plain = cands.filter((c) => !ways[c.wi].service);
    if (!plain.length) return null;
    cands = plain;
  } else {
    const svc = cands.filter((c) => ways[c.wi].service);
    if (svc.length) cands = svc;
  }
  const reach = Math.min(40, way.total);
  const incoming = end === 1
    ? unitBetween(way, Math.max(0, way.total - reach), way.total)
    : unitBetween(way, Math.min(way.total, reach), 0);
  let best = null;
  let bestScore = -Infinity;
  for (const c of cands) {
    const w = ways[c.wi];
    const leaveReach = Math.min(40, w.total);
    const leave = c.enterEnd === 0
      ? unitBetween(w, 0, leaveReach)
      : unitBetween(w, w.total, Math.max(0, w.total - leaveReach));
    let score = incoming[0] * leave[0] + incoming[1] * leave[1];
    if (w.railway && w.railway === way.railway) score += 0.05;
    if (way.ref && w.ref === way.ref) score += 0.2;
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  return best;
}

function walkDir(ways, adj, startWi, startAlong, dir, maxMetres) {
  const out = [];
  let travelled = 0;
  const seen = new Set();
  let wi = startWi;
  let along = startAlong;
  let d = dir;
  for (let hops = 0; hops < 500 && travelled < maxMetres; hops++) {
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
      if (travelled >= maxMetres) return out;
    }
    const next = chooseNext(ways, adj, wi, d > 0 ? 1 : 0, seen);
    if (!next) break;
    wi = next.wi;
    if (next.enterEnd === 0) {
      along = 0;
      d = 1;
    } else {
      along = ways[wi].total;
      d = -1;
    }
  }
  return out;
}

function snapStops(line, stops) {
  const snapped = [];
  for (const stop of stops) {
    const xy = [mercX(stop.lng), mercY(stop.lat)];
    const limit = stop.kind === 'position' ? POSITION_M : STATION_M;
    let best = null;
    for (let i = 1; i < line.length; i++) {
      const a = line[i - 1];
      const b = line[i];
      const proj = projectSeg(xy, a.xy, b.xy);
      if (proj.d > limit) continue;
      const chain = a.chain + proj.t * (b.chain - a.chain);
      if (!best || proj.d < best.d) best = { d: proj.d, chain, name: stop.name || '', kind: stop.kind };
    }
    if (best) snapped.push(best);
  }
  const positions = snapped.filter((s) => s.kind === 'position');
  return snapped.filter((s) => s.kind === 'position'
    || !positions.some((p) => Math.abs(p.chain - s.chain) < SAME_STOP_M));
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
 * The run from the previous stop to the next one.
 *
 * @param {object} o
 * @param {object[]} o.ways `{id, points:[[lng,lat]], railway, service, ref}`
 * @param {object[]} o.stops `{lng, lat, name, kind}`
 * @param {number} o.wayId the way that was clicked
 * @param {number} o.lng
 * @param {number} o.lat
 * @param {number} [o.maxMetres]
 * @returns {{points: number[][], from: string|null, to: string|null}|null}
 */
export function spanBetweenStops({ ways: raw, stops, wayId, lng, lat, maxMetres = 20000 }) {
  const { ways, adj } = prepare(raw);
  const seed = ways.findIndex((w) => w.id === wayId || String(w.id) === String(wayId));
  if (seed < 0) return null;
  const here = locate(ways[seed], [mercX(lng), mercY(lat)]);
  const back = walkDir(ways, adj, seed, here.along, -1, maxMetres);
  const fore = walkDir(ways, adj, seed, here.along, 1, maxMetres);
  const line = [];
  for (let i = back.length - 1; i >= 1; i--) line.push({ xy: back[i].xy, chain: -back[i].chain });
  for (const p of fore) line.push(p);
  if (line.length < 2) return null;

  const seedBack = Math.max(line[0].chain, -here.along);
  const seedFore = Math.min(line[line.length - 1].chain, ways[seed].total - here.along);
  const kept = snapStops(line, stops || []);
  const behind = kept.filter((s) => s.chain <= -STOP_GAP_M);
  const ahead = kept.filter((s) => s.chain >= STOP_GAP_M);
  const lo = behind.length ? Math.max(...behind.map((s) => s.chain)) : seedBack;
  const hi = ahead.length ? Math.min(...ahead.map((s) => s.chain)) : seedFore;
  if (!(hi > lo + 0.5)) return null;
  const pts = cut(line, lo, hi);
  if (pts.length < 2) return null;
  const nameAt = (chain) => kept.find((s) => Math.abs(s.chain - chain) < 1)?.name || null;
  return {
    points: pts.map(([x, y]) => [lngOf(x), latOf(y)]),
    from: behind.length ? nameAt(lo) : null,
    to: ahead.length ? nameAt(hi) : null,
  };
}
