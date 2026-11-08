import assert from 'node:assert/strict';
import { buildTrips, dayDetail } from '../../src/trips.js';
import { trackData, trackFC } from '../../src/track-data.js';
import { pointToCell, mercX, mercY, normCol, colsOf } from '../../src/hexgrid.js';

const at = hour => new Date(2026, 6, 24, hour).getTime() / 1000;
const meta = new Map();
// Lenzburg → Spreitenbach → Zürich, then back through the same cells.
for (const [i, lng] of [8.17, 8.34, 8.54].entries()) {
  const [col, row] = pointToCell(0, mercX(lng), mercY(47.4));
  const entry = { source: 'timeline', firstAt: at(7 + i), lastAt: at(20 - i), hits: 2 };
  meta.set(`0/${normCol(col, colsOf(0))}/${row}`, [entry, { ...entry, source: 'phone' }]);
}
const trips = buildTrips(meta, [], { home: null });
assert.equal(trips.length, 1, 'an out-and-back is one trip');
assert.equal(trips[0].spots.length, 3, 'naming still counts unique places');
assert.equal(trips[0].points.length, 6, 'the track retains outbound and return visits without duplicate sources');
const lines = fc => fc.features.filter(f => f.geometry.type === 'LineString').map(f => f.geometry.coordinates);
const crossings = fc => lines(fc).flatMap(line => line.slice(1).map((p, i) => [line[i], p]))
  .filter(([a, b]) => (a[0] < 8.4) !== (b[0] < 8.4)).length;
const tripTrack = trackData(trips[0]);
assert.equal(crossings(tripTrack.track), 2, 'the valley is crossed once each way');
const day = dayDetail('2026-07-24', trips, [], meta);
assert.equal(day.cells, 3, 'revisits do not inflate the day cell count');
assert.equal(day.points.length, 6, 'day tracks preserve the return too');
assert.equal(crossings(trackData(day, day.key).track), 2);
assert.deepEqual(lines(trackData(day, day.key).track), lines(tripTrack.track), 'day and trip follow the same journey');
assert.deepEqual(lines(trackData(buildTrips(new Map([...meta].reverse()), [], { home: null })[0]).track), lines(tripTrack.track));

// The same timestamp across distant places gives neither an entry nor an exit
// location. The old loop still linked into its first cell and out of its last.
const point = (lng, time, lat = 47.4) => ({ lng, lat, at: time });
const broad = [point(8.1, 1), point(8.2, 2), point(8.5, 2), point(8.6, 3)];
assert.equal(lines(trackFC(broad)).length, 0, 'ambiguous groups break both sides of the thread');
assert.equal(trackFC(broad).features.length, 4, 'all evidence remains visible as dots');

// A grid migration can expand one coarse fix into many nearby fine cells.
const nearby = [point(8.17, 1), point(8.339, 2), point(8.341, 2), point(8.54, 3)];
const grouped = lines(trackFC(nearby));
assert.equal(grouped.length, 1);
assert.equal(grouped[0].length, 3, 'nearby tied cells describe one approximate fix');
const rounded = value => JSON.parse(JSON.stringify(value, (_, v) => typeof v === 'number' ? Math.round(v * 1e9) / 1e9 : v));
assert.deepEqual(rounded(grouped), rounded(lines(trackFC([nearby[0], nearby[2], nearby[1], nearby[3]]))), 'tied storage order cannot change the line');
const wrapped = lines(trackFC([point(179.99, 1, 0), point(179.999, 2, 0), point(-179.999, 2, 0), point(-179.99, 3, 0)]));
assert.equal(wrapped[0].length, 3, 'nearby fixes across the antimeridian stay together');
assert.ok(Math.abs(wrapped[0][1][0]) > 179, 'their centre stays at the antimeridian');
assert.equal(lines(trackFC([point(8.1, 1), point(8.2, 2), point(8.3, 200000), point(8.4, 200001)])).length, 2, 'long silences still break the line');
assert.equal(lines(trackFC([point(8.1, 1), point(8.2, 0), point(8.3, 3)])).length, 0, 'undated evidence breaks the line');
console.log('trip/day chronology, two valley crossings, tied timestamps and recording gaps: passed');
