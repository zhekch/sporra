// Clearing a region takes exactly the cells that belong to it, and the save
// of that clear still fits in what the server will accept.
//
// The cells are the same ones the region level paints: a cell is in the
// region `areaOfCell` names and in no other. The towns below are the ones
// area-attribution.mjs already uses, where a few kilometres is the difference
// between two cantons. The batches are the other half — one canton of logged
// cells can be more than MAX_CELLS_PER_MUTATE, and a request past that is
// refused, so the clear would vanish off the map and never be saved.
//
//   node scripts/test/region-clear.mjs

import { readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { areaOfCell, cellsInArea, WHOLE_COUNTRY } from '../../src/stats.js';
import { loadCountries, countryAt } from '../../src/countries.js';
import { loadRegions, regionsInCountry } from '../../src/regions.js';
import { pointToCell, mercX, mercY, colsOf, normCol } from '../../src/hexgrid.js';
import { MUTATE_BATCH, listBatches, mutateBatches } from '../../src/auth.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const json = async (name) => JSON.parse(await readFile(path.join(ROOT, 'src', name), 'utf8'));

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

const COLS = colsOf(0);
const cellAt = (lng, lat) => {
  const [col, row] = pointToCell(0, mercX(lng), mercY(lat));
  return `0/${normCol(col, COLS)}/${row}`;
};

console.log('\nA mutate stays under the server cap');
{
  const server = readFileSync(path.join(ROOT, 'server/index.js'), 'utf8');
  const cap = Number(/const MAX_CELLS_PER_MUTATE = (\d+)/.exec(server)?.[1]);
  check(cap > 0, 'the server names a mutate cap', String(cap));
  check(MUTATE_BATCH > 0 && MUTATE_BATCH <= cap, `a batch of ${MUTATE_BATCH} fits in ${cap}`);

  check(mutateBatches([], []).length === 0, 'an empty edit is no request');
  const exact = mutateBatches(Array.from({ length: MUTATE_BATCH }, (_, i) => `a${i}`), []);
  check(exact.length === 1 && exact[0].add.length === MUTATE_BATCH, 'a full batch is one request');

  const over = mutateBatches(
    Array.from({ length: MUTATE_BATCH }, (_, i) => `a${i}`),
    ['r0'],
  );
  check(over.length === 2, 'one cell past a full batch of adds is a second request', String(over.length));
  check(over[0].remove.length === 0 && over[1].add.length === 0 && over[1].remove.length === 1,
    'the overflow is the remove, not a second copy of the adds');
  check(over.every((b) => b.add.length + b.remove.length <= cap), 'neither request passes the cap');

  const rows = Array.from({ length: MUTATE_BATCH + 5 }, (_, i) => ['id' + i]);
  const restored = listBatches(rows);
  check(restored.length === 2 && restored[0].length === MUTATE_BATCH && restored[1].length === 5,
    'a restore splits the same way');
  check(listBatches([]).length === 0, 'and an empty restore does not');
}

await Promise.all([loadCountries(await json('countries.json')), loadRegions(await json('regions.json'))]);

// Eastern Switzerland, the same towns area-attribution.mjs pins: Gais is
// Appenzell Ausserrhoden, Appenzell is the canton it is surrounded by, and
// Altstätten is Sankt Gallen. A clear of one must not take the other two.
const TOWNS = {
  'Gais AR': [9.457, 47.361],
  'Appenzell AI': [9.409, 47.331],
  'Altstätten SG': [9.548, 47.377],
};
const cells = Object.fromEntries(Object.entries(TOWNS).map(([name, at]) => [name, cellAt(...at)]));

console.log('\nA region clear takes that region and nothing beside it');
{
  const region = areaOfCell('region', cells['Gais AR']);
  check(typeof region === 'string' && region.includes('Ausserrhoden'), 'Gais resolves to Appenzell Ausserrhoden', region);
  const taken = cellsInArea(Object.values(cells), 'region', region);
  check(taken.length === 1 && taken[0] === cells['Gais AR'],
    'clearing it takes the Gais cell and neither neighbour', taken.join(', '));
  check(areaOfCell('region', cells['Altstätten SG']) !== region, 'Altstätten is a different region');
  check(areaOfCell('region', cells['Appenzell AI']) !== region, 'Appenzell Innerrhoden is a different region');
}

console.log('\nA country with no regions is cleared as itself');
{
  const countries = await json('countries.json');
  let found = null;
  for (const country of countries) {
    if (!country.iso || regionsInCountry(country.iso) !== 0 || !country.geometry) continue;
    const polys = country.geometry.type === 'Polygon'
      ? [country.geometry.coordinates]
      : country.geometry.coordinates;
    const ring = polys?.[0]?.[0];
    if (!ring?.length) continue;
    const n = Math.min(ring.length - 1, 24);
    let lng = 0;
    let lat = 0;
    for (let i = 0; i < n; i++) {
      lng += ring[i][0];
      lat += ring[i][1];
    }
    lng /= n;
    lat /= n;
    if (countryAt(lng, lat)?.id !== country.id) continue;
    found = { country, at: [lng, lat] };
    break;
  }
  check(!!found, 'there is a country the dataset does not subdivide');
  if (found) {
    const id = cellAt(...found.at);
    const stand = `${WHOLE_COUNTRY}${found.country.id}`;
    check(areaOfCell('region', id) === stand, `${found.country.id} stands in as its own region`, areaOfCell('region', id));
    const taken = cellsInArea([id, cells['Gais AR']], 'region', stand);
    check(taken.length === 1 && taken[0] === id, 'clearing it does not take a Swiss cell');
  }
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
