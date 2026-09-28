// A click on a track paints the run from the stop before it to the stop after
// it, and not the siding that branches off on the way.
//
//   node scripts/test/rail-span.mjs

import { latOf, lngOf, mercX, mercY } from '../../src/hexgrid.js';
import {
  railSpanQuery, spanBetweenStops, stopKind, waysAndStops,
} from '../../src/rail-span.js';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

// Metres east and north of a point near Bern, as a lng/lat. The span works in
// Mercator, so the fixture is built there too — a degree of longitude is not a
// metre, and a test that pretends it is measures the projection.
const origin = [mercX(7.44), mercY(46.95)];
const ll = (east, north) => [lngOf(origin[0] + east), latOf(origin[1] + north)];
const way = (id, pts, extra = {}) => ({
  id,
  points: pts.map(([e, n]) => ll(e, n)),
  railway: 'rail',
  service: '',
  ref: '',
  ...extra,
});
const stop = (east, north, name, kind = 'station') => {
  const [lng, lat] = ll(east, north);
  return { lng, lat, name, kind };
};
const near = (p, east, north, tol = 8) => {
  const x = mercX(p[0]) - origin[0];
  const y = mercY(p[1]) - origin[1];
  return Math.hypot(x - east, y - north) < tol;
};
const xsOf = (span) => (span?.points ?? []).map((p) => mercX(p[0]) - origin[0]);

console.log('\nThe run is the stations either side of the click');
{
  const ways = [
    way(1, [[0, 0], [1000, 0]]),
    way(2, [[1000, 0], [2500, 0]]),
  ];
  const stops = [stop(200, 0, 'West'), stop(2200, 4, 'East')];
  const [lng, lat] = ll(600, 0);
  const span = spanBetweenStops({ ways, stops, wayId: 1, lng, lat });
  check(!!span, 'a click between two stations has a span');
  const from = span?.points[0];
  const to = span?.points[span.points.length - 1];
  check(from && near(from, 200, 0), 'it starts at the station behind', from && from.join(','));
  check(to && near(to, 2200, 0), 'and ends at the station ahead', to && to.join(','));
  check(span?.from === 'West' && span?.to === 'East', 'and names them', `${span?.from} → ${span?.to}`);
}

console.log('\nA straight track with no station is the whole track');
{
  const ways = [
    way(1, [[0, 0], [400, 0]]),
    way(2, [[400, 0], [1600, 0]], { service: 'crossover' }),
    way(3, [[1600, 0], [3000, 0]]),
  ];
  const [lng, lat] = ll(100, 0);
  const span = spanBetweenStops({ ways, stops: [], wayId: 1, lng, lat });
  const xs = xsOf(span);
  check(xs.length >= 2 && Math.min(...xs) < 10 && Math.max(...xs) > 2900,
    'it crosses every join, including one tagged as a crossover',
    xs.length ? `${Math.min(...xs).toFixed(0)}…${Math.max(...xs).toFixed(0)}` : 'none');
  check(span?.from == null && span?.to == null, 'and it has no station names');
  check(span?.fore?.why === 'end' && span?.back?.why === 'end', 'both ends ran out of track',
    `${span?.back?.why} ${span?.fore?.why}`);
}

console.log('\nA short way is extended until the stops');
{
  const ways = [
    way(1, [[0, 0], [80, 0]]),
    way(2, [[80, 0], [1800, 0]], { ref: '450' }),
  ];
  const stops = [stop(20, 0, 'A'), stop(1600, 0, 'B')];
  const [lng, lat] = ll(40, 0);
  const span = spanBetweenStops({ ways, stops, wayId: 1, lng, lat });
  const xs = (span?.points ?? []).map((p) => mercX(p[0]) - origin[0]);
  check(xs.length >= 2 && Math.min(...xs) < 30 && Math.max(...xs) > 1500,
    'the span crosses the join between the two ways',
    xs.length ? `${Math.min(...xs).toFixed(0)}…${Math.max(...xs).toFixed(0)}` : 'none');
}

console.log('\nA junction is the end, whichever branch looks straighter');
{
  const ways = [
    way(1, [[0, 0], [500, 0]]),
    way(2, [[500, 0], [1500, 0]]),
    way(3, [[500, 0], [500, 1000]]),
  ];
  const stops = [stop(1400, 0, 'Onward'), stop(500, 900, 'Branch')];
  const [lng, lat] = ll(200, 0);
  const span = spanBetweenStops({ ways, stops, wayId: 1, lng, lat });
  const end = span?.points?.[span.points.length - 1];
  check(end && near(end, 500, 0, 20), 'the run stops where the track splits', end && end.join(','));
  check(span?.to == null && span?.fore?.why === 'junction', 'and does not pick a branch', span?.fore?.why);
  const south = span?.points.some((p) => mercY(p[1]) - origin[1] < -20);
  check(!south, 'neither branch is painted');
}

console.log('\nOnly a station ends the run');
{
  check(stopKind({ railway: 'station' }) === 'station', 'a station is a station');
  check(stopKind({ railway: 'halt' }) == null, 'a halt is not');
  check(stopKind({ public_transport: 'stop_position', train: 'yes' }) == null,
    'a stop position on the rail is not');
  const ways = [
    way(1, [[0, 0], [2000, 0]]),
    way(2, [[2000, 0], [4000, 0]]),
  ];
  const stops = [
    stop(300, 60, 'Building', 'station'),
    stop(900, 0, 'Platform', 'position'),
    stop(1500, 0, 'Halt', 'halt'),
    stop(3600, 0, 'Far'),
  ];
  const [lng, lat] = ll(800, 0);
  const span = spanBetweenStops({ ways, stops, wayId: 1, lng, lat });
  check(span?.from === 'Building', 'a station beside the rail still ends the run', span?.from);
  check(span?.to === 'Far', 'a platform and a halt in between do not', span?.to);
}

console.log('\nThe query is only a way id and a place');
{
  check(railSpanQuery('190977019', 7.44, 46.95)?.includes('way(190977019)'), 'a real way is asked for by id');
  check(railSpanQuery('190977019', 7.44, 46.95)?.includes('way.hit'), 'and that way is kept even when it is a siding');
  check(railSpanQuery('abc', 7.44, 46.95) == null, 'a way id that is not digits is refused');
  check(railSpanQuery('12', 400, 0) == null, 'a longitude off the earth is refused');
  const parsed = waysAndStops([
    { type: 'way', id: 5, tags: { railway: 'rail', service: 'siding', ref: '1' }, geometry: [{ lon: 7, lat: 46 }, { lon: 7.01, lat: 46 }] },
    { type: 'node', id: 9, lat: 46, lon: 7, tags: { railway: 'station', name: 'Thun' } },
    { type: 'node', id: 10, lat: 46, lon: 7, tags: { public_transport: 'stop_position' } },
  ]);
  check(parsed.ways.length === 1 && parsed.ways[0].service === 'siding', 'a way keeps its service tag');
  check(parsed.stops.length === 1 && parsed.stops[0].name === 'Thun', 'a bus-like stop_position is dropped and the station is kept');
}

console.log(`\n${fail ? 'FAILED' : 'passed'}: ${pass} ok, ${fail} failed`);
process.exit(fail ? 1 : 0);
