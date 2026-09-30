// Colouring one open activity by speed or by elevation.
//
// The shared route layer stays the activity's own colour. This builds a second
// line, one short span at a time, for the activity the card is showing. A
// single gradient expression cannot do it: MapLibre's line-gradient is one
// ramp for the whole layer, restarted on every feature, and a route is several
// features once a pause has split it.

// A climb smaller than this is the barometer breathing. Painting it red to
// green would be a picture of that noise.
export const ELEV_FLAT_M = 8;
// Speeds closer than this, once a stop and a spike have been set aside, are
// one speed. The line stays a single colour rather than inventing a ramp.
export const SPEED_FLAT_MS = 0.4;

const RED = [214, 54, 42];
const YELLOW = [232, 184, 42];
const GREEN = [36, 158, 74];

const mix = (a, b, t) => {
  const u = Math.min(1, Math.max(0, t));
  const ch = (i) => Math.round(a[i] + (b[i] - a[i]) * u);
  return `rgb(${ch(0)}, ${ch(1)}, ${ch(2)})`;
};

/** 0 is red, 1 is green, and the middle is yellow so the two can be told apart. */
export function ramp(t) {
  const u = Math.min(1, Math.max(0, t));
  return u < 0.5 ? mix(RED, YELLOW, u * 2) : mix(YELLOW, GREEN, (u - 0.5) * 2);
}

function percentile(values, p) {
  const s = [...values].sort((a, b) => a - b);
  const i = (s.length - 1) * p;
  const lo = Math.floor(i);
  const hi = Math.ceil(i);
  if (lo === hi) return s[lo];
  const f = i - lo;
  return s[lo] * (1 - f) + s[hi] * f;
}

/**
 * The value of the span that ends at `index`.
 *
 * Speed is that span's own. Elevation is the two ends averaged, so a climb
 * colours the ground it actually crosses rather than only the point it arrives at.
 *
 * @param {Array<object>} samples from routeSamples
 * @param {'speed'|'elev'} metric
 * @param {number} index
 * @returns {number|null}
 */
export function spanValue(samples, metric, index) {
  const here = samples[index];
  const prev = samples[index - 1];
  if (!here || !prev || here.seg !== prev.seg) return null;
  if (metric === 'speed') return here.speed;
  if (here.ele == null && prev.ele == null) return null;
  if (here.ele == null) return prev.ele;
  if (prev.ele == null) return here.ele;
  return (here.ele + prev.ele) / 2;
}

/**
 * The scale this activity is coloured against. Its own, not a fixed one: a
 * walk and a ride would otherwise both come out one colour.
 *
 * Speed drops the slowest and fastest twentieth, so a traffic light or a
 * single bad fix does not flatten everything in between. `flat` means the
 * range that is left is too small to be a ramp.
 *
 * @param {Array<object>} samples
 * @param {'speed'|'elev'} metric
 * @returns {{lo:number, hi:number, flat:boolean}|null}
 */
export function metricDomain(samples, metric) {
  const values = [];
  for (let i = 1; i < samples.length; i++) {
    const v = spanValue(samples, metric, i);
    if (v != null && Number.isFinite(v)) values.push(v);
  }
  if (!values.length) return null;
  if (metric === 'speed') {
    const lo = percentile(values, 0.05);
    const hi = percentile(values, 0.95);
    return { lo, hi, flat: hi - lo < SPEED_FLAT_MS };
  }
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  return { lo, hi, flat: hi - lo < ELEV_FLAT_M };
}

const unitOf = (value, domain) => {
  if (domain.flat || domain.hi === domain.lo) return 0.5;
  return Math.min(1, Math.max(0, (value - domain.lo) / (domain.hi - domain.lo)));
};

/**
 * Speed: 0 is slow and red, 1 is fast and green.
 * Elevation: 0 is low and green, 1 is high and red.
 */
export function metricColor(metric, unit) {
  return metric === 'elev' ? ramp(1 - unit) : ramp(unit);
}

/**
 * One feature per span that has a value, coloured for `metric`.
 *
 * @param {Array<object>} samples
 * @param {'speed'|'elev'} metric
 */
export function metricCollection(samples, metric) {
  const domain = metricDomain(samples, metric);
  const features = [];
  if (!domain) return { type: 'FeatureCollection', features };
  for (let i = 1; i < samples.length; i++) {
    const v = spanValue(samples, metric, i);
    if (v == null) continue;
    const prev = samples[i - 1];
    const here = samples[i];
    features.push({
      type: 'Feature',
      properties: { color: metricColor(metric, unitOf(v, domain)), i },
      geometry: { type: 'LineString', coordinates: [[prev.lng, prev.lat], [here.lng, here.lat]] },
    });
  }
  return { type: 'FeatureCollection', features };
}
