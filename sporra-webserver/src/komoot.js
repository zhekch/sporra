// Komoot tours, straight from a share link — no file to export first.
//
// Komoot has no documented public API, but the one its own web app uses (v007)
// answers a plain GET and, unusually, sends `Access-Control-Allow-Origin: *`.
// That means the *browser* can read it directly: no proxy, no server round
// trip, no credentials of yours passing through anything. This file therefore
// runs entirely client-side, like the file importer next to it.
//
//   GET /api/v007/tours/<id>?share_token=…              → name, date, sport, distance
//   GET /api/v007/tours/<id>/coordinates?share_token=…  → { items: [{lat,lng,alt,t}] }
//
// `t` is milliseconds since the tour started, so the tour's own `date` turns
// the whole list into real timestamps — which is all the rest of the app needs
// to fold it into cells and count visits the usual way. A recording left open
// reports that clock as days, with every fix but the first piled on the end;
// `time_in_motion` is the duration the tour page shows, and it replaces the
// clock when the points themselves have no pace in them. The GPX download isn't
// needed at all: this is the same data, already parsed.
//
// Being undocumented, it can change without warning. Everything here fails
// with a readable message rather than assuming a shape.

import { ROUTE_MIN_SPEED_KMH, TRACK_GAP_SEC, segmentLength } from './routes.js';

const API = 'https://www.komoot.com/api/v007/tours';

// komoot.com, komoot.de, www.komoot.com — and nothing that merely contains the
// word. The obvious `/(^|\.)komoot\.[a-z.]+$/` looks equivalent and is not:
// `[a-z.]+` swallows dots, so `komoot.com.evil.io` matches it and a lookalike
// host is read as Komoot's. Requiring the last label to be a single run of
// letters is what pins it to the registrable domain.
const KOMOOT_HOST = /^(?:[a-z0-9-]+\.)*komoot\.[a-z]{2,}$/i;

/**
 * Pull a tour id (and share token, if the link carries one) out of whatever
 * was pasted: a full share URL, a plain /tour/<id> URL, or just the number.
 * @returns {{id:string, shareToken:string}|null}
 */
export function parseKomootUrl(input) {
  const text = String(input ?? '').trim();
  if (!text) return null;

  if (/^\d{4,}$/.test(text)) return { id: text, shareToken: '' };

  let url;
  try {
    url = new URL(text.includes('://') ? text : `https://${text}`);
  } catch {
    return null;
  }
  if (!KOMOOT_HOST.test(url.hostname)) return null;
  // /tour/2504447881 — also matches /de-de/tour/… and /smarttour/… variants.
  const id = /\/(?:smart)?tour\/(\d{4,})/i.exec(url.pathname)?.[1];
  if (!id) return null;
  return { id, shareToken: url.searchParams.get('share_token') ?? '' };
}

/**
 * Every tour link in a block of pasted text, in the order they appear and with
 * duplicates dropped.
 *
 * Deliberately not a split on newlines: people paste a column out of a
 * spreadsheet, a chat log with the links buried in sentences, or ten URLs
 * separated by spaces. Pulling out anything that looks like a link and letting
 * parseKomootUrl judge each one handles all of those the same way.
 *
 * A tour listed twice — once plain and once with a share token — keeps the one
 * carrying the token, since that is the version that can actually be fetched.
 * @returns {Array<{id:string, shareToken:string}>}
 */
export function parseKomootUrls(input) {
  const text = String(input ?? '');
  const byId = new Map();
  // Bare ids are only taken when nothing else is in the text; a URL contains
  // digits of its own and would otherwise be read twice.
  // Commas and semicolons end a link rather than belonging to it — otherwise
  // "tour/1,tour/2" is matched as one enormous URL and only the first id is
  // read. Everything else non-blank is fair game, including the query string.
  const candidates = text.match(/[^\s,;]*komoot\.[a-z.]+\/[^\s,;]*/gi) ?? text.split(/[\s,;]+/);
  for (const raw of candidates) {
    // Trailing punctuation from prose ("…share_token=abc.") is not part of it.
    const ref = parseKomootUrl(raw.replace(/[),.;'"]+$/, ''));
    if (!ref) continue;
    const seen = byId.get(ref.id);
    if (!seen || (!seen.shareToken && ref.shareToken)) byId.set(ref.id, ref);
  }
  return [...byId.values()];
}

/**
 * The canonical address of a tour: the id, and the share token if there is one.
 *
 * A link copied out of Komoot carries a tail of tracking — `ref=profile`,
 * `t_s=referral`, `t_cid=route_share`, `t_ref_username=…` — which says who
 * shared it with whom and is nobody's business once the tour is on your map.
 * The share token is *not* tracking: it is the only thing that opens a private
 * tour, so it is the one parameter kept.
 */
export function tourUrl({ id, shareToken } = {}) {
  if (!/^\d{4,}$/.test(String(id ?? ''))) return '';
  const base = `https://www.komoot.com/tour/${id}`;
  return shareToken ? `${base}?share_token=${encodeURIComponent(shareToken)}` : base;
}

/** True if this is a link we are willing to store and render as one. */
export function isKomootTourUrl(url) {
  try {
    const u = new URL(String(url ?? ''));
    if (u.protocol !== 'https:') return false;
    if (!KOMOOT_HOST.test(u.hostname)) return false;
    return /^\/(?:smart)?tour\/\d{4,}$/i.test(u.pathname);
  } catch {
    return false;
  }
}

async function get(path, shareToken) {
  const url = `${API}${path}${shareToken ? `${path.includes('?') ? '&' : '?'}share_token=${encodeURIComponent(shareToken)}` : ''}`;
  let res;
  try {
    res = await fetch(url, { headers: { Accept: 'application/hal+json' }, credentials: 'omit' });
  } catch {
    throw new Error('Could not reach Komoot. Check your connection.');
  }
  if (res.status === 403 || res.status === 401) {
    throw new Error(
      shareToken
        ? 'Komoot refused that share link — it may have been turned off or replaced.'
        : 'That tour is private. Use the share link (the one with share_token in it).',
    );
  }
  if (res.status === 404) throw new Error('Komoot has no tour with that id.');
  if (!res.ok) throw new Error(`Komoot answered ${res.status}.`);
  try {
    return await res.json();
  } catch {
    throw new Error('Komoot sent something this app could not read.');
  }
}

// Komoot's own sport keys are terse; these are just nicer to read on a card.
const SPORTS = {
  racebike: 'Road ride',
  touringbicycle: 'Bike tour',
  mtb: 'Mountain bike',
  mtb_easy: 'Mountain bike',
  mtb_advanced: 'Mountain bike',
  e_racebike: 'E-road ride',
  e_touringbicycle: 'E-bike tour',
  e_mtb: 'E-mountain bike',
  hike: 'Hike',
  mountaineering: 'Mountaineering',
  jogging: 'Run',
  running: 'Run',
  nordicwalking: 'Nordic walking',
  skating: 'Skating',
  climbing: 'Climbing',
  downhillbike: 'Downhill',
  unicycle: 'Unicycle',
  other: '',
};

export const sportLabel = (key) => SPORTS[key] ?? '';

// The same test `recordedSeconds` uses. A span slower than this was a clock
// left running, and covering the tour's own distance at that pace is how you
// can tell without already knowing the answer.
const clockBelievable = (metres, sec) =>
  sec > 0 && metres > 0 && (metres / 1000) / (sec / 3600) >= ROUTE_MIN_SPEED_KMH;

// Time that is not inside the single longest hole. A collapsed recording is
// one hole with the fixes piled at either end of it; a real ride still has
// its own span once that hole is taken out.
function spanBesideLongestGap(points) {
  let span = 0;
  let biggest = 0;
  for (let i = 1; i < points.length; i++) {
    const dt = (points[i].t || 0) - (points[i - 1].t || 0);
    if (dt > 0) span += dt;
    if (dt > biggest) biggest = dt;
  }
  return span - biggest;
}

// The points carry no pace: put the ride's duration along the line, so the
// card, the graph and the summary all measure the same hour. Distance, not
// index — a long straight and a cluster of fixes at a junction are not the
// same amount of the ride.
function spreadOver(points, seconds) {
  const cum = [0];
  for (let i = 1; i < points.length; i++) cum.push(cum[i - 1] + segmentLength([points[i - 1], points[i]]));
  const total = cum[cum.length - 1];
  const last = points.length - 1;
  for (let i = 0; i < points.length; i++) {
    const frac = total > 0 ? cum[i] / total : last ? i / last : 0;
    points[i].t = Math.round(frac * seconds);
  }
}

/**
 * How long this tour took, and point timestamps that agree with it.
 *
 * `duration` is wall-clock time and `time_in_motion` is what the tour page
 * prints. Both are seconds. On a recording that was actually stopped they
 * agree with the coordinates, and those coordinates are kept — the pauses in
 * them are real. On one that was not, the wall clock and the coordinates are
 * the same absurd span (one tour: 163 hours for 11.8 km, every fix but the
 * first sharing that timestamp) while the page still says 1 h 49 min. That
 * moving time is the one the route is given, spread along the line because a
 * single timestamp has nothing to graph.
 *
 * Points come in as seconds from the start and leave as unix seconds when
 * `startedAt` is known. An undated tour keeps `t` at 0: a small offset would
 * otherwise read as 1970.
 *
 * @param {Array<{lat:number,lng:number,t:number}>} points
 * @returns {{durationSec:number, lastAt:number}}
 */
export function applyKomootClock(points, { motionSec = 0, wallSec = 0, lengthM = 0, startedAt = 0 } = {}) {
  const motion = Math.max(0, Math.round(+motionSec || 0));
  const wall = Math.max(0, Math.round(+wallSec || 0));
  const lastT = points.length ? points[points.length - 1].t || 0 : 0;
  const span = points.length > 1 ? lastT - (points[0].t || 0) : 0;
  const metres = lengthM > 0 ? lengthM : segmentLength(points);
  const believable = (sec) => clockBelievable(metres, sec);
  const collapsed = span > 0 && !believable(span) && spanBesideLongestGap(points) < TRACK_GAP_SEC;
  // Moving time first: it is the number on the page. The wall clock is only
  // a fallback for a tour that never recorded one.
  const trusted = believable(motion) ? motion : believable(wall) ? wall : 0;

  let durationSec;
  let endOffset;
  if (collapsed && trusted) {
    spreadOver(points, trusted);
    durationSec = trusted;
    endOffset = trusted;
  } else if (span > 0 && believable(span) && wall > 0 && !believable(wall)) {
    // The coordinates already describe the ride. Extending them out to a
    // wall clock that fails the same test is how a good line becomes a
    // week-long one. The moving time is not substituted either: the pauses
    // in a real line are part of how long it took.
    durationSec = span;
    endOffset = lastT;
  } else {
    durationSec = wall || motion || span;
    endOffset = wall || lastT;
  }

  const start = Math.floor(+startedAt) || 0;
  if (start) {
    for (const p of points) p.t += start;
  } else {
    for (const p of points) p.t = 0;
  }
  return { durationSec, lastAt: start ? start + endOffset : 0 };
}

/**
 * Fetch one tour and turn it into the shapes the rest of the app already
 * understands: flat `points` for the cell folding, and a `tracks` entry (the
 * same shape src/locations.js produces) for the saved route.
 *
 * @returns {Promise<{tour, points:Array<{lat,lng,t}>, tracks:Array<object>}>}
 */
export async function fetchTour({ id, shareToken }) {
  const tour = await get(`/${encodeURIComponent(id)}`, shareToken);
  const coords = await get(`/${encodeURIComponent(id)}/coordinates`, shareToken);
  const items = Array.isArray(coords?.items) ? coords.items : [];
  if (!items.length) throw new Error('That tour has no recorded coordinates.');

  // `t` counts milliseconds from the start; without a start date the points
  // simply carry no time, and the usual undated fallbacks take over.
  const startedAt = Math.floor(Date.parse(tour?.date ?? '') / 1000) || 0;
  const points = [];
  for (const it of items) {
    const lat = +it?.lat;
    const lng = +it?.lng;
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;
    if (Math.abs(lat) > 90 || Math.abs(lng) > 180) continue;
    const offset = Number.isFinite(+it?.t) ? Math.round(+it.t / 1000) : 0;
    const p = { lat, lng, t: offset };
    if (Number.isFinite(+it?.alt)) p.ele = +it.alt;
    points.push(p);
  }
  if (!points.length) throw new Error('That tour has no usable coordinates.');

  const { durationSec, lastAt } = applyKomootClock(points, {
    motionSec: tour?.time_in_motion,
    wallSec: tour?.duration,
    lengthM: +tour?.distance || 0,
    startedAt,
  });
  const name = String(tour?.name ?? '').trim();
  return {
    tour: {
      id: String(tour?.id ?? id),
      name,
      sport: sportLabel(tour?.sport),
      planned: tour?.type === 'tour_planned',
      startedAt,
      // Komoot's own numbers, kept for the preview: the distance it reports is
      // the one you'd see on its site, which need not match what the simplified
      // line measures out to here.
      distanceM: +tour?.distance || 0,
      durationSec,
    },
    points,
    tracks: [{ name, segments: [points], firstAt: startedAt, lastAt, sport: sportLabel(tour?.sport) }],
  };
}
