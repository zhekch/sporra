// A route that leaves a map tile and comes back must not be one feature.
//
// Mapbox joins the two crossings with a stroke along the tile edge. Cutting
// the line at every crossing stops that, and also dashes the route: the short
// pieces fall under the source's simplification and never get drawn. The cut
// is only the return. A line that crosses a tile once stays one feature, which
// is what keeps a few hundred routes from becoming tens of thousands.
//
//   node scripts/test/route-tiles.mjs

import { ROUTE_TILE_ZOOM, routesToFC, splitLineAtTileBounds } from '../../src/routes.js';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};
const eq = (got, want, label) =>
  check(got === want, label, `got ${JSON.stringify(got)}, wanted ${JSON.stringify(want)}`);

const RAD = Math.PI / 180;
const tileXY = (lng, lat, z = ROUTE_TILE_ZOOM) => {
  const n = 2 ** z;
  const x = ((lng + 180) / 360) * n;
  const s = Math.sin(lat * RAD);
  const y = (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * n;
  return [x, y];
};
const latOfY = (y, z = ROUTE_TILE_ZOOM) => {
  const n = Math.PI * (1 - (2 * y) / 2 ** z);
  return (Math.atan(Math.sinh(n)) * 180) / Math.PI;
};

// The edge the bite was drawn on: z11 row 722, which is an integer row at
// every finer zoom too. A few hundred metres south of it and back is the shape.
const EDGE_Y = 722 * 2 ** (ROUTE_TILE_ZOOM - 11);
const edgeLat = latOfY(EDGE_Y);
// Both ends come back into the *same* tile. A return one column over is a
// different tile, and that one does not close.
const wiggle = [
  [7.40, edgeLat + 0.004],
  [7.40, edgeLat - 0.005],
  [7.401, edgeLat + 0.004],
];

const pieces = splitLineAtTileBounds(wiggle);
check(pieces.length > 1, 'a there-and-back across a tile edge is more than one piece', `${pieces.length}`);
check(pieces.length <= 4, 'and only the return is cut, not every tile it crosses', `${pieces.length}`);

const south = pieces.find((line) => line.some((p) => p[1] < edgeLat - 1e-8));
check(!!south, 'the southern tip is still on a piece');

// The chord would be a long segment that stays on the edge latitude and skips
// the tip. Nothing we emit is that segment.
const chord = pieces.some((line) => line.some((p, i) => {
  if (!i) return false;
  const a = line[i - 1];
  const b = p;
  return Math.abs(a[1] - edgeLat) < 1e-7 && Math.abs(b[1] - edgeLat) < 1e-7 && Math.abs(a[0] - b[0]) > 0.002;
}));
check(!chord, 'no piece runs along the tile edge between the two crossings');

const shared = [];
for (let i = 1; i < pieces.length; i++) {
  const prev = pieces[i - 1];
  shared.push([prev[prev.length - 1], pieces[i][0]]);
}
check(shared.every(([a, b]) => a[0] === b[0] && a[1] === b[1]), 'adjacent pieces share the cut vertex');
check(
  shared.every(([a]) => {
    const [x, y] = tileXY(a[0], a[1]);
    return Math.abs(x - Math.round(x)) < 1e-6 || Math.abs(y - Math.round(y)) < 1e-6;
  }),
  'and that vertex is on a tile edge',
);

const emitted = pieces.flat();
check(
  wiggle.every((p) => emitted.some((q) => Math.abs(q[0] - p[0]) < 1e-12 && Math.abs(q[1] - p[1]) < 1e-12)),
  'every original vertex survives the cut',
);

// Cutting twice changes nothing: the endpoints are already on the grid.
const again = pieces.flatMap((line) => splitLineAtTileBounds(line));
eq(again.length, pieces.length, 'cutting an already-cut line does not cut it again');

// A straight run crosses dozens of tiles and never comes back to one. Cutting
// each of those was the dash, and the stall.
const diagonal = splitLineAtTileBounds([[7.40, 46.78], [7.55, 46.90]]);
eq(diagonal.length, 1, 'a straight run across many tiles stays one piece');
eq(diagonal[0][0][0], 7.40, 'it still starts where the line started');
const last = diagonal[diagonal.length - 1];
eq(last[last.length - 1][1], 46.90, 'and ends where the line ended');

// A line that never meets a grid line stays one piece, including its third
// coordinate.
const quiet = splitLineAtTileBounds([[7.4, 46.75, 500], [7.4001, 46.7501, 520]]);
eq(quiet.length, 1, 'a line inside one tile stays one piece');
eq(quiet[0][1][2], 520, 'and keeps a height it was given');

// The date line is not a few hundred tiles of Switzerland. Leave it whole.
const wrapped = splitLineAtTileBounds([[179.9, 46.7], [-179.9, 46.8]]);
eq(wrapped.length, 1, 'an antimeridian jump is not walked tile by tile');

// --- The collection the map actually receives ------------------------------------
const fc = routesToFC([
  { id: 5, name: 'Thun', sport: 'Mountain cycling', geom: [wiggle, [[7.5, 46.7], [7.51, 46.71]]] },
  { id: 9, name: 'empty', sport: '', geom: [] },
]);
check(fc.features.length > 1 && fc.features.length <= 6, 'the return is cut and the second segment stays whole', `${fc.features.length}`);
check(fc.features.every((f) => f.properties.id === 5 && f.id === 5), 'every piece keeps the route id');
check(
  fc.features.every((f) => f.geometry.type === 'LineString'),
  'and each feature is one line',
);
eq(fc.features[0].properties.sport, 'Mountain cycling', 'the activity still rides on the feature');
check(
  !fc.features.some((f) => f.properties.id === 9),
  'a route with no geometry is not drawn',
);

// Two segments of one route stay two chains. The gap between them is a pause,
// and the cut must not stitch it shut.
const chains = [];
let chain = [fc.features[0]];
for (let i = 1; i < fc.features.length; i++) {
  const prev = chain[chain.length - 1].geometry.coordinates;
  const here = fc.features[i].geometry.coordinates;
  const a = prev[prev.length - 1];
  const b = here[0];
  if (a[0] === b[0] && a[1] === b[1]) chain.push(fc.features[i]);
  else {
    chains.push(chain);
    chain = [fc.features[i]];
  }
}
chains.push(chain);
eq(chains.length, 2, 'a gap between segments is still a gap');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
