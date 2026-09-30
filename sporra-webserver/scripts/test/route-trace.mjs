// Elevation and time stay beside the line, and speed is worked out from them.
//
// The route's key is a hash of its coordinates. A second import of the same
// file, with heights this time, has to be the same route — so the heights
// cannot be part of that hash, and a trace that does not line up with the
// line has to be refused rather than drawn in the wrong place.
//
//   node scripts/test/route-trace.mjs

import { alignTrace, buildRoute, haversine, nearestSample, routeSamples } from '../../src/routes.js';
import { metricColor } from '../../src/route-metric.js';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

const T0 = 1_700_000_000;

function line(n, lng0, lat, t0, ele0) {
  return Array.from({ length: n }, (_, i) => ({
    lng: lng0 + i * 0.002,
    // A bend of about 25 m. Far enough that thinning keeps it, close enough
    // that it is not read as a teleport and split out of the segment.
    lat: lat + (i === 3 ? 0.00022 : 0),
    t: t0 + i * 10,
    ele: ele0 + i * 3,
  }));
}

function ride(eleA, eleB) {
  const a = line(8, 7.4, 46.9, T0, eleA);
  const b = line(6, 7.55, 47.05, T0 + 500, eleB);
  // A shoreline is 0 m. A point the file never measured is not.
  a[a.length - 1].ele = undefined;
  return buildRoute(
    { name: 'Loop', segments: [a, b], firstAt: T0, lastAt: T0 + 550, sport: 'Cycling' },
    { source: 'gpx' },
  );
}

const low = ride(500, 800);
const high = ride(900, 100);
check(!!low && low.trace?.length === 2, 'a route keeps a trace beside its line');
check(low.trace[0].length === low.geom[0].length && low.trace[1].length === low.geom[1].length,
  'the trace lines up with the geometry',
  `${low.trace[0].length}/${low.geom[0].length}, ${low.trace[1].length}/${low.geom[1].length}`);
check(low.trace[0].some((p) => p[0] === null), 'a missing height stays null',
  `got ${JSON.stringify(low.trace[0])}`);
check(low.trace[0][0][0] === 500, 'a measured height is kept', `got ${low.trace[0][0][0]}`);
check(low.key === high.key, 'two builds of the same line share a key', `${low.key} vs ${high.key}`);
check(low.trace[0][0][0] !== high.trace[0][0][0], 'and their heights stay their own');

const samples = routeSamples(low.geom, low.trace);
const span = haversine(samples[0], samples[1]) / (samples[1].t - samples[0].t);
check(Math.abs(samples[1].speed - span) < 1e-6, 'a span’s speed is its own distance over its own time',
  `got ${samples[1].speed} want ${span}`);
check(samples[0].elapsed === 0 && samples[1].elapsed === samples[1].t - samples[0].t,
  'elapsed time is measured from the start',
  `got ${samples[0].elapsed}, ${samples[1].elapsed}`);

const jump = samples.findIndex((s) => s.seg === 1);
const endOfFirst = samples[jump - 1];
check(jump > 1 && samples[jump].speed == null, 'the break between segments is not a speed');
check(samples[jump].distM === endOfFirst.distM, 'and the jump is not added to the distance',
  `${samples[jump].distM} vs ${endOfFirst.distM}`);

check(alignTrace(low.geom, [low.trace[0].slice(0, 2)]) === null, 'a short trace is refused');
const last = samples.length - 1;
check(nearestSample(samples, samples[last].lng, samples[last].lat) === last,
  'a tap lands on the nearest stored point');
check(nearestSample([], 0, 0) === -1, 'and nowhere, when there is nothing stored');

const channels = (color) => color.match(/rgb\((\d+), (\d+), (\d+)\)/).slice(1).map(Number);
const slow = channels(metricColor('speed', 0));
const fast = channels(metricColor('speed', 1));
check(slow[0] > fast[0] && fast[1] > slow[1], 'slow is redder than fast');
const valley = channels(metricColor('elev', 0));
const ridge = channels(metricColor('elev', 1));
check(valley[1] > ridge[1] && ridge[0] > valley[0], 'low is greener than high, and high is redder');

console.log(`\n${fail ? 'FAILED' : 'passed'}: ${pass} ok, ${fail} failed`);
process.exit(fail ? 1 : 0);
