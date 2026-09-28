// The railway between the stop before a click and the stop after it.
//
// The tiles can say which way was clicked. They cannot say where that way
// goes: a way ends at the next switch, and the geometry in a tile ends at the
// tile. One Overpass query returns the ways and the stops around the click —
// personal scale, one request per click, kept for a few minutes so painting
// the same run again does not ask twice. Two endpoints, because the public
// instances take turns being the one that answers.

import { mercX, mercY } from '../src/hexgrid.js';
import { RAIL_SPAN_RADIUS_M, railSpanQuery, spanBetweenStops, waysAndStops } from '../src/rail-span.js';

const ENDPOINTS = [
  'https://overpass.openstreetmap.fr/api/interpreter',
  'https://lz4.overpass-api.de/api/interpreter',
];

const USER_AGENT = 'Sporra/0.106.1 (+https://github.com/zhekch/sporra; personal map)';
const CACHE_MS = 10 * 60 * 1000;
const FAIL_MS = 20 * 1000;
// Bern's station throat is about 2 MB. Past this the answer is not a span,
// it is a dump, and painting it would be a guess.
const MAX_BYTES = 12_000_000;

const cache = new Map();

async function overpass(query) {
  // A string, not the URLSearchParams object: the first fetch consumes a body
  // stream, and the second endpoint would then post nothing.
  const body = new URLSearchParams({ data: query }).toString();
  for (const url of ENDPOINTS) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'User-Agent': USER_AGENT,
          Accept: 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body,
        signal: AbortSignal.timeout(22000),
      });
      if (!res.ok) continue;
      const buf = Buffer.from(await res.arrayBuffer());
      if (buf.length > MAX_BYTES) continue;
      const parsed = JSON.parse(buf.toString('utf8'));
      if (!Array.isArray(parsed.elements)) continue;
      return parsed.elements;
    } catch {
      /* the other instance */
    }
  }
  return null;
}

/**
 * @param {string} wayId
 * @param {number} lng
 * @param {number} lat
 * @returns {Promise<{points: number[][], from: string|null, to: string|null}|null>}
 */
const apart = (a, b) => Math.hypot(mercX(a.lng) - mercX(b.lng), mercY(a.lat) - mercY(b.lat));

export async function railSpan(wayId, lng, lat) {
  const first = railSpanQuery(wayId, Number(lng), Number(lat));
  if (!first) return null;
  const key = `${wayId}:${Number(lat).toFixed(3)}:${Number(lng).toFixed(3)}`;
  const hit = cache.get(key);
  if (hit && hit.until > Date.now()) return hit.value;

  let elements = [];
  let origin = { lng: Number(lng), lat: Number(lat) };
  const asked = new Set();
  let span = null;
  // Each hop is another circle along an end that ran out of track at the rim.
  // Four is about fifty kilometres, which is past the next station on any
  // line this is aimed at. A dead end inside a circle is not asked again.
  for (let hop = 0; hop < 4; hop++) {
    const qk = `${origin.lat.toFixed(2)}:${origin.lng.toFixed(2)}`;
    if (asked.has(qk)) break;
    asked.add(qk);
    const query = railSpanQuery(wayId, origin.lng, origin.lat);
    const batch = query && await overpass(query);
    if (!batch) break;
    elements = elements.concat(batch);
    span = spanBetweenStops({
      ...waysAndStops(elements),
      wayId: Number(wayId),
      lng: Number(lng),
      lat: Number(lat),
    });
    if (!span) break;
    const edge = [span.back, span.fore].find((end) =>
      (end.why === 'end' || end.why === 'limit')
      && apart(origin, end) > RAIL_SPAN_RADIUS_M - 2000);
    if (!edge) break;
    origin = { lng: edge.lng, lat: edge.lat };
  }
  const value = span && { points: span.points, from: span.from, to: span.to };
  cache.set(key, { until: Date.now() + (value ? CACHE_MS : FAIL_MS), value });
  if (cache.size > 40) cache.delete(cache.keys().next().value);
  return value;
}
