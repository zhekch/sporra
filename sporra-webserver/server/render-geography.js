import { readFileSync } from 'node:fs';
import { loadCountries, countryNear, searchCountries } from '../src/countries.js';
import { loadRegions, regionNear, regionsInCountry, searchRegions } from '../src/regions.js';
import { loadPlaces, searchPlaces, nearestTown } from '../src/places.js';
import { areaOfCell, WHOLE_COUNTRY } from '../src/stats.js';
import { continentOf } from '../src/continents.js';
import { tallyAreas, areaFeatures } from '../src/area-render.js';
import { cellStats, heatMetric, areaColorOf } from '../src/coloring.js';
import { rollUp, finishRollUpSteps, storedUnder } from '../src/rollup.js';
import { summarizeCells } from '../src/cell-info-data.js';
import { tripRelevance, parseDateQuery, tripInPeriod } from '../src/search-data.js';
import { fold } from '../src/fold.js';
import { mercX, mercY, pointToCell, colsOf, normCol, brushRadius, cellsWithin, cellsOnPolyline } from '../src/hexgrid.js';

const accounts = new Map();
const prepared = new WeakMap();
const areaAnswers = new WeakMap();
export function forget(userId) {
  if (userId === undefined) accounts.clear(); else accounts.delete(userId);
}
export function inputFor(userId, signature, supply) {
  let held = accounts.get(userId);
  if (!held || held.signature !== signature) {
    held = { signature, input: supply() };
    accounts.delete(userId); accounts.set(userId, held);
    if (accounts.size > 8) accounts.delete(accounts.keys().next().value);
  }
  return held.input;
}
let priming;
export function prime() {
  return priming ??= Promise.all([
    loadCountries(JSON.parse(readFileSync(new URL('../src/countries.json', import.meta.url)))),
    loadRegions(JSON.parse(readFileSync(new URL('../src/regions.json', import.meta.url)))),
    loadPlaces(JSON.parse(readFileSync(new URL('../src/places.json', import.meta.url)))),
  ]);
}
function geography(kind, id) {
  const country = areaOfCell(kind === 'continent' ? 'country' : kind, id);
  return kind === 'continent' ? country && continentOf(country) : country;
}
function prepare(input, hidden = []) {
  let variants = prepared.get(input);
  if (!variants) prepared.set(input, variants = new Map());
  const key = JSON.stringify([...new Set(hidden)].sort());
  if (variants.has(key)) return variants.get(key);
  const rolled = rollUp(input.cellIds, (id, type) => cellStats(input.cellMeta.get(id), type), { byType: true, hidden: new Set(hidden) });
  for (const _ of finishRollUpSteps(rolled, true)) {}
  variants.set(key, rolled);
  if (variants.size > 4) variants.delete(variants.keys().next().value);
  return rolled;
}
export async function regions(input, options) {
  await prime();
  let answers = areaAnswers.get(input);
  if (!answers) areaAnswers.set(input, answers = new Map());
  const key = JSON.stringify([options.level, options.mode, options.accent, options.hidden]);
  if (answers.has(key)) return answers.get(key);
  const kind = ['region', 'country', 'continent'][options.level - 6];
  const rolled = prepare(input, options.hidden);
  const { litIds, perArea } = tallyAreas(kind, options.mode === 'type', {
    sourceOrder: rolled.sourceOrder, visibleCells: rolled.shown ?? input.cellIds,
    areaOfCellMemo: geography, cellStatsOf: (id, type) => cellStats(input.cellMeta.get(id), type),
  });
  const fc = areaFeatures(kind, options.mode, false, litIds, perArea, [], heatMetric(options.mode));
  const color = areaColorOf(options.mode, options.accent);
  for (const feature of fc.features) feature.properties.color = color(feature.properties.v);
  answers.set(key, fc);
  if (answers.size > 4) answers.delete(answers.keys().next().value);
  return fc;
}
export function coordinate(lng, lat) {
  if (lng === null || lat === null || String(lng).trim() === '' || String(lat).trim() === '' || !Number.isFinite(+lng) || !Number.isFinite(+lat) || Math.abs(+lng) > 180 || Math.abs(+lat) > 85.051129) throw new Error('invalid coordinates');
  return [+lng, +lat];
}
export async function at(input, lng, lat, level, hidden = []) {
  await prime();
  const rolled = prepare(input, hidden);
  const visible = rolled.shown ?? input.cellIds;
  let ids, name = nearestTown(lng, lat)?.name ?? 'Visited area', area = null;
  if (level < 6) {
    const [col, row] = pointToCell(level, mercX(lng), mercY(lat));
    const key = `${normCol(col, colsOf(level))}/${row}`;
    ids = storedUnder(rolled.litSets, level, key);
  } else {
    const country = countryNear(lng, lat);
    if (!country) return { visited: false, lng, lat, level };
    const kind = ['region', 'country', 'continent'][level - 6];
    const region = kind === 'region' ? regionNear(lng, lat, country.iso) : null;
    const id = kind === 'country' ? country.id : kind === 'continent' ? continentOf(country.id) : region?.id ?? (regionsInCountry(country.iso) === 0 ? WHOLE_COUNTRY + country.id : null);
    area = { kind, id, name: region?.name ?? (kind === 'continent' ? id : country.id) };
    name = area.name;
    ids = [...visible].filter((cell) => geography(kind, cell) === id);
  }
  return { visited: ids.length > 0, name, area, level, lng, lat, ...summarizeCells(ids, input.cellMeta) };
}
export async function search(query, routes = [], trips = []) {
  await prime();
  const q = String(query ?? '').trim().slice(0, 100);
  if (q.length < 2) return [];
  const period = parseDateQuery(q);
  const named = trips.map(t => ({ ...t, kind: 'trip', rank: period ? (tripInPeriod(t, period) ? 0 : Infinity) : tripRelevance(t, fold(q)) }))
    .filter(t => Number.isFinite(t.rank)).sort((a,b) => a.rank - b.rank || b.start - a.start).slice(0,8);
  const activity = routes.filter(r => fold(r.name).includes(fold(q))).slice(0,8).map(r => ({...r, kind:'route'}));
  return [...searchRegions(q), ...searchCountries(q), ...searchPlaces(q), ...named, ...activity];
}
export function brush(body) {
  const level = body.level ?? 0;
  const size = body.size ?? 1;
  if (!Number.isInteger(level) || level < 0 || level > 5 || !Number.isInteger(size) || size < 1 || size > 99) throw new Error('invalid brush level or size');
  if (!['paint', 'erase'].includes(body.action)) throw new Error('action must be paint or erase');
  if (!Array.isArray(body.points) || !body.points.length || body.points.length > 2000) throw new Error('stroke requires 1–2000 points');
  const points = body.points.map(p => { if (!Array.isArray(p) || p.length !== 2) throw new Error('invalid point'); const [lng, lat] = coordinate(...p);return [mercX(lng), mercY(lat)]; });
  // Reject enormous segments before cellsOnPolyline can sample them.
  for (let i = 1; i < points.length; i++) if (Math.hypot(points[i][0] - points[i-1][0], points[i][1] - points[i-1][1]) > 100000) throw new Error('stroke segment exceeds 100 km');
  const ids = new Set();
  for (const [col, row] of cellsOnPolyline(level, points)) {
    for (const [c, r] of cellsWithin(col, row, Math.max(0, brushRadius(size) - 1))) {
      ids.add(`${level}/${normCol(c, colsOf(level))}/${r}`);
      if (ids.size > 50000) throw new Error('stroke exceeds 50000 cells');
    }
  }
  return [...ids];
}
export async function regionClear(input, lng, lat) {
  await prime();
  const country = countryNear(lng, lat);
  if (!country) return [];
  const region = regionNear(lng, lat, country.iso);
  const id = region?.id ?? (regionsInCountry(country.iso) === 0 ? WHOLE_COUNTRY + country.id : null);
  return id ? input.cellIds.filter(cell => geography('region', cell) === id) : [];
}

export function storedForBrush(input, ids) {
  const rolled = prepare(input);
  const out = new Set();
  for (const id of ids) {
    const [level, col, row] = id.split('/').map(Number);
    for (const stored of storedUnder(rolled.litSets, level, `${col}/${row}`)) out.add(stored);
  }
  if (out.size > 50000) throw new Error('erase exceeds 50000 stored cells');
  return [...out];
}
