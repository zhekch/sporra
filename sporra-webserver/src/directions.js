// A line between two places, dense enough to colour the cells it crosses.
//
// Car is the FOSSGIS OSRM demo: one driving route, full geometry, GeoJSON.
// That server is a shared resource — one request a second, a named User-Agent,
// and the OpenStreetMap credit — so the page never calls it. The server does,
// once, when someone asks for a line. See server/directions.js.
//
// Train is Transitous, which is MOTIS over open timetable feeds. A direct
// walking route is left off the request on purpose: MOTIS drops any transit
// journey that loses to the fastest direct one, and a walk across a city would
// hide the train. The walk to the first stop and from the last one stays,
// because those are how the tapped points meet the service. Empty
// `directModes` is that choice. `TRANSIT` is every public mode, and the first
// itinerary is whichever arrives soonest — between two cities that is often a
// coach, drawn along the streets. The button is Train, so the request is the
// rail group (long-distance, regional, suburban, metro). A leg that comes
// back as a bus or a coach is refused rather than coloured in.

export const CAR_ROUTER = 'https://routing.openstreetmap.de/routed-car/route/v1/driving';
export const TRAIN_ROUTER = 'https://api.transitous.org/api/v6/plan';

// `RAIL` is MOTIS's own group: high-speed, long-distance, night, regional,
// metro and subway. Suburban (an S-Bahn) sits outside that group, and a trip
// to the main station often starts on one, so it is named beside it. Trams
// and coaches are left out: both are drawn along the street.
const TRAIN_MODES = 'RAIL,SUBURBAN';

// What a leg is allowed to be once the answer comes back. The group name
// itself rarely appears on a leg; the specific mode does.
const RAIL_LEG = new Set([
  'RAIL',
  'HIGHSPEED_RAIL',
  'LONG_DISTANCE',
  'NIGHT_RAIL',
  'REGIONAL_RAIL',
  'REGIONAL_FAST_RAIL',
  'SUBURBAN',
  'SUBWAY',
  'METRO',
]);

// Two taps on the same junction are not a trip. Thirty metres is inside one
// cell of this grid, so a shorter request would colour nothing new.
const MIN_LEG_M = 30;

/**
 * @param {{lng:number, lat:number}} a
 * @param {{lng:number, lat:number}} b
 */
export function placesApart(a, b) {
  if (!a || !b) return false;
  const lat = ((a.lat + b.lat) / 2) * Math.PI / 180;
  const dx = (a.lng - b.lng) * Math.cos(lat) * 111_320;
  const dy = (a.lat - b.lat) * 110_540;
  return Math.hypot(dx, dy) >= MIN_LEG_M;
}

/**
 * @param {{lng:number, lat:number}} p
 * @returns {boolean}
 */
export function placeOk(p) {
  return !!p
    && Number.isFinite(p.lng) && Number.isFinite(p.lat)
    && p.lat >= -90 && p.lat <= 90
    && p.lng >= -180 && p.lng <= 180;
}

/**
 * Google's encoded polyline, as `[lng, lat]`.
 *
 * MOTIS says which precision the string was built with (6 on the v6 plan
 * endpoint, 5 on OSRM's default). The factor is the only thing that changes.
 *
 * @param {string} str
 * @param {number} [precision]
 * @returns {Array<[number, number]>}
 */
export function decodePolyline(str, precision = 5) {
  if (typeof str !== 'string' || !str) return [];
  const factor = 10 ** precision;
  let index = 0;
  let lat = 0;
  let lng = 0;
  const out = [];
  const read = () => {
    let result = 0;
    let shift = 0;
    let byte = 0;
    do {
      if (index >= str.length) return 0;
      byte = str.charCodeAt(index++) - 63;
      result += (byte & 0x1f) * (2 ** shift);
      shift += 5;
    } while (byte >= 0x20);
    return (result & 1) ? ~(result >> 1) : result >> 1;
  };
  while (index < str.length) {
    lat += read();
    lng += read();
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) break;
    out.push([lng / factor, lat / factor]);
  }
  return out;
}

/**
 * @param {{lng:number, lat:number}} from
 * @param {{lng:number, lat:number}} to
 */
export function carRequestUrl(from, to) {
  const url = new URL(`${CAR_ROUTER}/${from.lng},${from.lat};${to.lng},${to.lat}`);
  // `overview=full` is the road, not the simplified line OSRM would send for
  // the highest zoom. A simplified one skips the bends the colour has to follow.
  url.searchParams.set('overview', 'full');
  url.searchParams.set('geometries', 'geojson');
  url.searchParams.set('steps', 'false');
  return url.toString();
}

/**
 * @param {{lng:number, lat:number}} from
 * @param {{lng:number, lat:number}} to
 */
export function trainRequestUrl(from, to) {
  const url = new URL(TRAIN_ROUTER);
  // MOTIS takes latitude first. OSRM takes longitude first. Both are right
  // for the engine that wrote the parameter.
  url.searchParams.set('fromPlace', `${from.lat},${from.lng}`);
  url.searchParams.set('toPlace', `${to.lat},${to.lng}`);
  url.searchParams.set('transitModes', TRAIN_MODES);
  url.searchParams.set('directModes', '');
  url.searchParams.set('preTransitModes', 'WALK');
  url.searchParams.set('postTransitModes', 'WALK');
  url.searchParams.set('detailedLegs', 'true');
  url.searchParams.set('timetableView', 'false');
  url.searchParams.set('numItineraries', '1');
  return url.toString();
}

/**
 * @param {unknown} body
 * @returns {Array<[number, number]>|null}
 */
export function lineFromOsrm(body) {
  const geom = body?.routes?.[0]?.geometry;
  if (!geom || body?.code !== 'Ok') return null;
  const coords = typeof geom === 'string'
    ? decodePolyline(geom, 5)
    : Array.isArray(geom.coordinates) ? geom.coordinates : null;
  return cleanLine(coords);
}

/**
 * The first itinerary, legs in order, one line.
 *
 * A leg whose feed has no shape still has the two stops. The straight join is
 * what keeps the colour from breaking at a station the timetable never drew.
 *
 * @param {unknown} body
 * @returns {Array<[number, number]>|null}
 */
export function lineFromTransitous(body) {
  const legs = body?.itineraries?.[0]?.legs;
  if (!Array.isArray(legs) || !legs.length) return null;
  // The request already asks for rail. This is the same refusal on the way
  // back: a coach that slipped into the first itinerary used to be painted
  // as the train, along the road it drives.
  const labelled = legs.some((leg) => typeof leg?.mode === 'string' && leg.mode);
  const onRails = legs.some((leg) => RAIL_LEG.has(leg?.mode));
  const offRails = legs.some((leg) => {
    const mode = leg?.mode;
    return typeof mode === 'string' && mode && mode !== 'WALK' && !RAIL_LEG.has(mode);
  });
  if (offRails || (labelled && !onRails)) return null;
  const line = [];
  for (const leg of legs) {
    const geom = leg?.legGeometry;
    let pts = [];
    if (geom && typeof geom.points === 'string' && geom.points) {
      const precision = Number.isInteger(geom.precision) ? geom.precision : 6;
      pts = decodePolyline(geom.points, precision);
    }
    if (pts.length < 2) {
      const a = pointOf(leg?.from);
      const b = pointOf(leg?.to);
      if (a && b) pts = [a, b];
    }
    appendLine(line, pts);
  }
  return line.length >= 2 ? line : null;
}

function pointOf(place) {
  const lng = place?.lon;
  const lat = place?.lat;
  if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;
  return [lng, lat];
}

function cleanLine(coords) {
  if (!Array.isArray(coords)) return null;
  const line = [];
  for (const p of coords) {
    if (!Array.isArray(p) || p.length < 2) continue;
    const lng = Number(p[0]);
    const lat = Number(p[1]);
    if (!Number.isFinite(lng) || !Number.isFinite(lat)) continue;
    appendLine(line, [[lng, lat]]);
  }
  return line.length >= 2 ? line : null;
}

function appendLine(line, pts) {
  if (!pts?.length) return;
  let start = 0;
  const last = line[line.length - 1];
  if (last && last[0] === pts[0][0] && last[1] === pts[0][1]) start = 1;
  for (let i = start; i < pts.length; i++) line.push(pts[i]);
}
