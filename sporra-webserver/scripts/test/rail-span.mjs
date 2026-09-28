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
const stop = (east, north, name, kind = 'position') => {
  const [lng, lat] = ll(east, north);
  return { lng, lat, name, kind };
};

console.log('\nThe run is the stops either side of the click');
{
  const ways = [
    way(1, [[0, 0], [1000, 0]]),
    way(2, [[1000, 0], [2500, 0]]),
    way(3, [[1000, 0], [1000, -800]], { service: 'siding' }),
  ];
  const stops = [stop(200, 0, 'West'), stop(2200, 4, 'East')];
  const [lng, lat] = ll(600, 0);
  const span = spanBetweenStops({ ways, stops, wayId: 1, lng, lat });
  check(!!span, 'a click between two stops has a span');
  const from = span?.points[0];
  const to = span?.points[span.points.length - 1];
  const near = (p, east, north) => {
    const x = mercX(p[0]) - origin[0];
    const y = mercY(p[1]) - origin[1];
    return Math.hypot(x - east, y - north) < 8;
  };
  check(from && near(from, 200, 0), 'it starts at the stop behind', from && from.join(','));
  check(to && near(to, 2200, 0), 'and ends at the stop ahead', to && to.join(','));
  check(span?.from === 'West' && span?.to === 'East', 'and names them', `${span?.from} → ${span?.to}`);
  const south = span?.points.some((p) => mercY(p[1]) - origin[1] < -20);
  check(!south, 'the siding is not part of the run');
}

console.log('\nNo stop means the way that was clicked, not the line it joins');
{
  const ways = [
    way(1, [[0, 0], [400, 0]]),
    way(2, [[400, 0], [3000, 0]]),
  ];
  const [lng, lat] = ll(100, 0);
  const span = spanBetweenStops({ ways, stops: [], wayId: 1, lng, lat });
  check(!!span, 'the way itself is still a span');
  const xs = span.points.map((p) => mercX(p[0]) - origin[0]);
  check(Math.min(...xs) > -5 && Math.max(...xs) < 410, 'it does not run on into the next way',
    `${Math.min(...xs).toFixed(0)}…${Math.max(...xs).toFixed(0)}`);
  check(span.from == null && span.to == null, 'and it has no stop names');
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

console.log('\nThe straight line wins at a fork');
{
  const ways = [
    way(1, [[0, 0], [500, 0]]),
    way(2, [[500, 0], [1500, 0]]),
    way(3, [[500, 0], [500, 1000]]),
  ];
  const stops = [stop(1400, 0, 'Onward'), stop(500, 900, 'Branch')];
  const [lng, lat] = ll(200, 0);
  const span = spanBetweenStops({ ways, stops, wayId: 1, lng, lat });
  check(span?.to === 'Onward', 'the continuation is the straight one', span?.to);
}

console.log('\nA station beside the rail counts, and a bus stop does not');
{
  check(stopKind({ railway: 'halt' }) === 'station', 'a halt is a stop');
  check(stopKind({ public_transport: 'stop_position', train: 'yes' }) === 'position',
    'a train stop_position is on the rail');
  check(stopKind({ public_transport: 'stop_position', highway: 'bus_stop' }) == null,
    'a bus stop_position is not');
  const ways = [way(1, [[0, 0], [2000, 0]])];
  const stops = [stop(300, 60, 'Building', 'station'), stop(1700, 0, 'Far')];
  const [lng, lat] = ll(800, 0);
  const span = spanBetweenStops({ ways, stops, wayId: 1, lng, lat });
  check(span?.from === 'Building', 'a station 60 m off the rail still ends the run', span?.from);
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
