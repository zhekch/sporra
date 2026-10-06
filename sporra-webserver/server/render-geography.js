import { readFileSync } from 'node:fs';
import { loadCountries, countryNear, searchCountries, countryIso, countryGeometry, countryAreaKm2 } from '../src/countries.js';
import { loadRegions, regionNear, regionsInCountry, searchRegions, countriesInView, regionById, addFineRegions, addFineOutline, seamedRegion, fineRegionsVersion, regionGeometry, geometryAreaM2 } from '../src/regions.js';
import { loadPlaces, searchPlaces, nearestTown } from '../src/places.js';
import { areaOfCell, WHOLE_COUNTRY, cellAreaKm2 } from '../src/stats.js';
import { continentOf, continentAreaKm2 } from '../src/continents.js';
import { tallyAreas, areaFeatures, areaGeometry } from '../src/area-render.js';
import { cellStats, heatMetric, areaColorOf } from '../src/coloring.js';
import { rollUp, finishRollUpSteps, storedUnder } from '../src/rollup.js';
import { summarizeCells } from '../src/cell-info-data.js';
import { tripRelevance, parseDateQuery, tripInPeriod } from '../src/search-data.js';
import { fold } from '../src/fold.js';
import { mercX, mercY, pointToCell, colsOf, normCol, brushRadius, cellsWithin, cellsOnPolyline, parseCellId, cellCenter, project } from '../src/hexgrid.js';

const accounts = new Map();
const prepared = new WeakMap();
const areaAnswers = new WeakMap();
const sharpened = new Map();
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
export async function regions(input, options, supplyFine) {
  await prime();
  let answers = areaAnswers.get(input);
  if (!answers) areaAnswers.set(input, answers = new Map());

  const kind = ['region', 'country', 'continent'][options.level - 6];
  const rolled = prepare(input, options.hidden);
  const { litIds, perArea } = tallyAreas(kind, options.mode === 'type', {
    sourceOrder: rolled.sourceOrder, visibleCells: rolled.shown ?? input.cellIds,
    areaOfCellMemo: geography, cellStatsOf: (id, type) => cellStats(input.cellMeta.get(id), type),
  });
  const fine = options.level < 8 && options.fine;
  if (fine && supplyFine) {
    const views = options.bbox[0] > options.bbox[2]
      ? [[options.bbox[0], options.bbox[1], 180, options.bbox[3]], [-180, options.bbox[1], options.bbox[2], options.bbox[3]]]
      : [options.bbox];
    const regionIds = kind === 'region' ? litIds : new Set([...rolled.shown ?? input.cellIds].map(id => geography('region', id)));
    const isos = new Set(views.flatMap(view => countriesInView(regionIds, view).map(c => c.iso)));
    // Countries with no ADM1 records still have a detailed country outline.
    for (const id of litIds) {
      const country = kind === 'country' ? id : id.startsWith(WHOLE_COUNTRY) ? id.slice(WHOLE_COUNTRY.length) : null;
      if (!country) continue;
      const geometry = countryGeometry(country);
      const polygons = geometry?.type === 'Polygon' ? [geometry.coordinates] : geometry?.coordinates ?? [];
      if (polygons.some(poly => {
        let west = Infinity, east = -Infinity, south = Infinity, north = -Infinity;
        for (const [lng, lat] of poly[0]) {
          west = Math.min(west, lng); east = Math.max(east, lng);
          south = Math.min(south, lat); north = Math.max(north, lat);
        }
        return views.some(([w,s,e,n]) => east >= w && west <= e && north >= s && south <= n);
      })) isos.add(countryIso(country));
    }
    await Promise.all([...isos].filter(Boolean).map(async iso => {
      let task = sharpened.get(iso);
      if (!task) {
        task = (async () => {
          const body = await supplyFine(iso);
          if (!body) return;
          addFineOutline(iso, body.outline);
          if (!seamedRegion(iso, body.regions)) addFineRegions(body.regions);
        })();
        sharpened.set(iso, task);
        task.catch(() => sharpened.delete(iso));
      }
      await task;
    }));
  }
  const key = JSON.stringify([options.level, options.mode, options.accent, options.hidden, options.info, fine, fine ? fineRegionsVersion() : 0]);
  if (answers.has(key)) return answers.get(key);
  const fc = areaFeatures(kind, options.mode, fine, litIds, perArea, [], heatMetric(options.mode));
  if (options.info) {
    const idsByArea = new Map();
    for (const id of rolled.shown ?? input.cellIds) {
      const area = geography(kind, id);
      if (!area) continue;
      if (!idsByArea.has(area)) idsByArea.set(area, []);
      idsByArea.get(area).push(id);
    }
    fc.infoFeatures = [...idsByArea].flatMap(([id, cells]) => {
      const geometry = areaGeometry(kind, id, fine);
      if (!geometry) return [];
      const name = kind === 'region' ? regionById(id)?.name ?? id.replace(WHOLE_COUNTRY, '') : id;
      return [{ type: 'Feature', geometry, properties: { name, visited: true, area: { kind, id, name }, ...coverageFacts({ kind, id, name }, cells), ...summarizeCells(cells, input.cellMeta) } }];
    });
  }
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
function coverageFacts(area, ids) {
  let covered = 0;
  for (const id of ids) {
    const [level, col, row] = parseCellId(id);
    if (Number.isFinite(level)) covered += cellAreaKm2(level, project(cellCenter(level, col, row))[1]);
  }
  const country = area.id?.startsWith(WHOLE_COUNTRY) ? area.id.slice(WHOLE_COUNTRY.length) : area.id;
  const geometry = area.kind === 'region' && !area.id?.startsWith(WHOLE_COUNTRY) ? regionGeometry(area.id) : null;
  const whole = area.kind === 'continent' ? continentAreaKm2(area.id) : area.kind === 'region' && !area.id?.startsWith(WHOLE_COUNTRY) ? (geometry ? geometryAreaM2(geometry) / 1e6 : 0) : countryAreaKm2(country);
  const iso = area.kind === 'country' ? countryIso(country) : null;
  const of = iso ? regionsInCountry(iso) : 0;
  const regions = new Set(ids.map(id => geography('region', id)).filter(id => id && !id.startsWith(WHOLE_COUNTRY)));
  return { covered, coveredPct: whole ? covered / whole * 100 : 0, coveredOf: area.name, areaKm2: whole, ...(of ? { inside: { label: 'Regions visited', n: regions.size, of } } : {}) };
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
  return { visited: ids.length > 0, name, area, level, lng, lat, ...summarizeCells(ids, input.cellMeta), ...(area ? { ...coverageFacts(area, ids), geometry: areaGeometry(area.kind, area.id, true) } : {}) };
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
