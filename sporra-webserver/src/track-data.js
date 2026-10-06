import { dayBounds, dayKey, dayLabel, distanceKm } from './trips.js';
/** Longer a silence than this and the thread is cut rather than drawn across. */
const TRACK_LINK_GAP_SEC = 36 * 3600;

/**
 * Points in time order → dots, plus the thread between them.
 *
 * One source, two geometry types: a circle layer ignores the lines and a line
 * layer ignores the points, so this stays a single setData.
 */
export function trackFC(points) {
  const features = [];
  let run = [];
  let prev = 0;
  const cut = () => {
    if (run.length > 1) {
      features.push({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: run } });
    }
    run = [];
  };
  for (const p of points ?? []) {
    if (!Number.isFinite(p?.lng) || !Number.isFinite(p?.lat)) continue;
    features.push({ type: 'Feature', properties: {}, geometry: { type: 'Point', coordinates: [p.lng, p.lat] } });
    // Nothing to thread them with, and the dots stand on their own. Three
    // reasons a point doesn't join the one before it:
    //
    //   no time at all      — it can't be placed in the order
    //   the *same* time     — neither can it. A whole afternoon's worth of
    //                         ground imported from one photo album carries one
    //                         timestamp on every cell of it, and joining those
    //                         in the order they happen to come out of storage
    //                         draws a zigzag and calls it a route
    //   a long gap          — a day out and the next day out are two threads,
    //                         not one line drawn across the night between them
    if (!p.at || (prev && p.at <= prev)) {
      cut();
      if (p.at) run.push([p.lng, p.lat]);
      prev = p.at || 0;
      continue;
    }
    if (prev && p.at - prev > TRACK_LINK_GAP_SEC) cut();
    run.push([p.lng, p.lat]);
    prev = p.at;
  }
  cut();
  return { type: 'FeatureCollection', features };
}


// The box around a set of points, for framing a day. A trip carries its own,
// worked out when it was derived; a day is assembled on demand and doesn't.
export function bboxOfPoints(points) {
  const b = [Infinity, Infinity, -Infinity, -Infinity];
  for (const p of points ?? []) {
    if (!Number.isFinite(p?.lng) || !Number.isFinite(p?.lat)) continue;
    b[0] = Math.min(b[0], p.lng);
    b[1] = Math.min(b[1], p.lat);
    b[2] = Math.max(b[2], p.lng);
    b[3] = Math.max(b[3], p.lat);
  }
  return b.every(Number.isFinite) ? b : null;
}


export function trackData(item, day = null) {
  const points = item.points ?? item.spots ?? [];
  const track = trackFC(points);
  let km = 0;
  for (const f of track.features) {
    if (f.geometry.type !== 'LineString') continue;
    for (let i = 1; i < f.geometry.coordinates.length; i++) {
      km += distanceKm(...f.geometry.coordinates[i-1], ...f.geometry.coordinates[i]);
    }
  }
  const firstDay = item.start ? dayKey(item.start) : null;
  const from = day ? item.start : firstDay ? dayBounds(firstDay)[0] : null;
  const to = day ? item.end : item.end ? dayBounds(dayKey(item.end))[1] : null;
  return { ...item, track, bbox: item.bbox ?? bboxOfPoints(points), label: day ? dayLabel(day) : item.name, firstDay, from, to, km };
}
