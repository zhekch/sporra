// The refinement from a 600 m hex to a 50 m one: lines fill every cell they
// cross, a corridor is not a town, and a trace snaps to the railway it
// actually follows.
//
//   node scripts/test/grid-migrate.mjs

import {
  ACCEPT_M,
  chainTrace,
  chooseNetwork,
  classify,
  cellsInside,
  haversine,
  matchTrace,
  neighborIds,
  newCellId,
  oldCellId,
  rasterize,
  traceLength,
} from '../grid-migrate.mjs';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

console.log('\na line fills the cells it crosses');
{
  const a = [7.45, 46.95];
  const step = 400 / (111_320 * Math.cos((46.95 * Math.PI) / 180));
  const b = [7.45 + step, 46.95];
  const ids = rasterize([a, b]);
  check(ids.size >= 4, '400 m of road is more than one 50 m cell', `${ids.size} cells`);
  check(ids.has(newCellId(a[0], a[1])) && ids.has(newCellId(b[0], b[1])), 'both ends are in it');
}

console.log('\ncorridors, towns, specks');
{
  let id = oldCellId(7.45, 46.95);
  const line = [id];
  for (let i = 0; i < 11; i++) {
    const row = Number(id.split('/')[2]);
    const col = id.split('/')[1];
    const next = neighborIds(id).find((n) => n.split('/')[1] === col && Number(n.split('/')[2]) === row + 1);
    check(!!next, 'the grid has a northern neighbour');
    line.push(next);
    id = next;
  }
  const found = classify(line);
  check(found.chains.length === 1 && found.chains[0].length === 12, 'twelve cells in a row are one chain',
    `${found.chains.length} chains, city ${found.city.length}, specks ${found.specks.length}`);
  check(found.city.length === 0 && found.specks.length === 0, 'and neither a town nor a speck');

  const centre = oldCellId(8.5, 47.2);
  const around = neighborIds(centre).slice(0, 4);
  const town = classify([centre, ...around]);
  check(town.city.includes(centre), 'four neighbours make the middle a town',
    `city ${town.city.length}`);
}

console.log('\nwhich network a chain belongs to');
{
  const road = { coords: [[0, 0], [1, 0]], meanM: 80, frac: 0.9 };
  const rail = { coords: [[0, 0], [1, 0]], meanM: 120, frac: 0.9 };
  check(chooseNetwork(road, rail, { lengthM: 5_000 })?.kind === 'road', 'a short chain takes the closer one');
  check(chooseNetwork(road, rail, { lengthM: 30_000 })?.kind === 'rail',
    'a long chain prefers the railway when it is within 150 m of the road');
  check(chooseNetwork(road, null, { lengthM: 40_000, speedMps: 200 }) == null,
    'a flight is not pulled onto a motorway');
  check(chooseNetwork(road, rail, { lengthM: 40_000, speedMps: 200 })?.kind === 'rail',
    'the same speed on a railway still is one');
  check(chooseNetwork({ ...road, meanM: ACCEPT_M + 50 }, null) == null, 'outside the old hex is not a match');
}

console.log('\na bend stays a bend');
{
  const east = 2_000 / (111_320 * Math.cos((47 * Math.PI) / 180));
  const north = 2_000 / 110_540;
  const corner = [7 + east, 47];
  const road = { kind: 'road', coords: [[7, 47], corner, [corner[0], 47 + north]] };
  const trace = [];
  const push = (lng, lat) => trace.push({ lng, lat, t: 0 });
  for (let i = 0; i <= 4; i++) push(7 + east * (i / 4), 47);
  for (let i = 1; i <= 4; i++) push(corner[0], 47 + north * (i / 4));
  const matched = matchTrace(trace, [road]);
  check(matched != null, 'the road explains the trace', matched && `mean ${matched.meanM.toFixed(0)} m`);
  if (matched) {
    let nearest = Infinity;
    for (const p of matched.coords) nearest = Math.min(nearest, haversine(p, corner));
    check(nearest < 80, 'the matched line passes the corner, rather than cutting it', `${nearest.toFixed(0)} m`);
    const straight = haversine(matched.coords[0], corner) + haversine(corner, matched.coords[matched.coords.length - 1]);
    check(traceLength(trace.map((p) => ({ lng: p.lng, lat: p.lat }))) > 3000, 'the fixture is a real bend');
    check(straight > 3000, 'and so is the geometry we kept', `${straight.toFixed(0)} m`);
  }
  const far = trace.map((p) => ({ ...p, lat: p.lat + 1 }));
  check(matchTrace(far, [road]) == null, 'a trace a degree away is not that road');
}

console.log('\nstreets are clipped to the hexes that were marked');
{
  const old = oldCellId(7.45, 46.95);
  const centre = chainTrace([old])[0];
  const dx = 0.02;
  const ids = cellsInside([[centre.lng - dx, centre.lat], [centre.lng + dx, centre.lat]], new Set([old]));
  check(ids.size > 0 && ids.size < rasterize([[centre.lng - dx, centre.lat], [centre.lng + dx, centre.lat]]).size,
    'only the part inside the old hex is kept', `${ids.size} cells`);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
