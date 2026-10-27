import { dayBounds, dayKey, dayLabel, distanceKm } from './trips.js';
/** Longer a silence than this and the thread is cut rather than drawn across. */
const TRACK_LINK_GAP_SEC = 36 * 3600;
/** A coarse fix expanded into fine cells still describes one small location. */
const TRACK_SAME_TIME_RADIUS_KM = 0.5;

/**
 * Points in time order → dots, plus the thread between them.
 *
 * One source, two geometry types: a circle layer ignores the lines and a line
 * layer ignores the points, so this stays a single setData.
 */
export function trackFC(points) {
  points = points ?? [];
  const features = [];
  let run = [];
  let prev = 0;
  const cut = () => {
    if (run.length > 1) {
      features.push({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: run } });
    }
    run = [];
  };
  const valid = p => Number.isFinite(p?.lng) && Number.isFinite(p?.lat);
  for (const p of points) {
    if (!valid(p)) continue;
    features.push({ type: 'Feature', properties: {}, geometry: { type: 'Point', coordinates: [p.lng, p.lat] } });
  }
  for (let i = 0; i < points.length;) {
    const p = points[i++];
    if (!valid(p) || !Number.isFinite(p.at) || p.at <= 0) {
      cut();
      prev = 0;
      continue;
    }
    const group = [p];
    while (i < points.length && points[i]?.at === p.at && valid(points[i])) group.push(points[i++]);
    // Choosing the first or last cell in a tied group depends on storage order
    // and draws arbitrary chords. Nearby simultaneous cells are one approximate
    // fix (including old coarse cells expanded by the grid migration). A broad
    // group has no known order, so neither side may connect through it.
    const wrap = lng => ((lng + 180) % 360 + 360) % 360 - 180;
    const lng = wrap(p.lng + group.reduce((sum, q) => sum + wrap(q.lng - p.lng), 0) / group.length);
    const lat = group.reduce((sum, q) => sum + q.lat, 0) / group.length;
    if (group.some(q => distanceKm(lng, lat, q.lng, q.lat) > TRACK_SAME_TIME_RADIUS_KM)) {
      cut();
      prev = 0;
      continue;
    }
    if (prev && p.at <= prev) cut();
    if (prev && p.at - prev > TRACK_LINK_GAP_SEC) cut();
    run.push([lng, lat]);
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
