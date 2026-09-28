// The railway between the stop before a click and the stop after it.
//
// The tiles can say which way was clicked. They cannot say where that way
// goes: a way ends at the next switch, and the geometry in a tile ends at the
// tile. One Overpass query returns the ways and the stops around the click —
// personal scale, one request per click, kept for a few minutes so painting
// the same run again does not ask twice. Two endpoints, because the public
// instances take turns being the one that answers.

import { railSpanQuery, spanBetweenStops, waysAndStops } from '../src/rail-span.js';

const ENDPOINTS = [
  'https://overpass.openstreetmap.fr/api/interpreter',
  'https://lz4.overpass-api.de/api/interpreter',
];

const USER_AGENT = 'Sporra/0.105 (+https://github.com/zhekch/sporra; personal map)';
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
export async function railSpan(wayId, lng, lat) {
  const query = railSpanQuery(wayId, lng, lat);
  if (!query) return null;
  const key = `${wayId}:${Number(lat).toFixed(3)}:${Number(lng).toFixed(3)}`;
  const hit = cache.get(key);
  if (hit && hit.until > Date.now()) return hit.value;
  const elements = await overpass(query);
  const span = elements
    ? spanBetweenStops({ ...waysAndStops(elements), wayId: Number(wayId), lng: Number(lng), lat: Number(lat) })
    : null;
  cache.set(key, { until: Date.now() + (span ? CACHE_MS : FAIL_MS), value: span });
  if (cache.size > 40) cache.delete(cache.keys().next().value);
  return span;
}
