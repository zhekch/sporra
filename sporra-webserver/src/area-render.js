// Geometry, aggregation and colour scales shared by both rendering clients.
import { WHOLE_COUNTRY } from './stats.js';
import { TYPE_MAX, hotOf, ageStopsOf } from './coloring.js';
import { countryGeometry, countryIso, mergeCountries } from './countries.js';
import { regionGeometry, fineCountryOutline, mergeRegions } from './regions.js';
import { continentGeometry, mergeContinents } from './continents.js';
import { asMulti, unionGeometries } from './polygon.js';

const sharpCountry = (id, fine) =>
  (fine ? fineCountryOutline(countryIso(id)) : null) ?? countryGeometry(id);

export function areaGeometry(kind, id, fine) {
  if (kind === 'continent') return continentGeometry(id);
  const country = id.startsWith(WHOLE_COUNTRY) ? id.slice(WHOLE_COUNTRY.length) : null;
  if (country) return sharpCountry(country, fine);
  return kind === 'region' ? regionGeometry(id, fine) : sharpCountry(id, fine);
}

export function mergeAreas(kind, litIds, fine) {
  if (kind === 'continent') return mergeContinents(litIds);
  if (kind !== 'region') {
    if (!fine) return mergeCountries(litIds);
    // Same dissolve, over the sharper outlines where they have been fetched.
    // Done here rather than inside mergeCountries so that countries.js does not
    // have to know that regions exist.
    const geoms = [];
    for (const id of litIds) {
      const g = sharpCountry(id, true);
      if (g) geoms.push(asMulti(g));
    }
    return geoms.length ? unionGeometries(geoms) : { fill: [], rings: [] };
  }
  const plain = new Set();
  const extra = [];
  for (const id of litIds) {
    if (id.startsWith(WHOLE_COUNTRY)) {
      const g = countryGeometry(id.slice(WHOLE_COUNTRY.length));
      if (g) extra.push(asMulti(g));
    } else {
      plain.add(id);
    }
  }
  if (!extra.length) return mergeRegions(plain, fine);
  const merged = mergeRegions(plain, fine);
  return unionGeometries([...(merged.fill.length ? [merged.fill] : []), ...extra]);
}

export function tallyAreas(kind, byType, { sourceOrder, visibleCells, areaOfCellMemo, cellStatsOf }) {
  const isContinentKind = kind === 'continent';
  const slotOf = byType ? new Map(sourceOrder.map((src, i) => [src, i])) : null;
  const litIds = new Set();
  // Continent → the countries in it you have been to. The count is the whole
  // point of the level; the set is what makes it a count of countries rather
  // than of cells that happen to be in them.
  const countriesIn = isContinentKind ? new Map() : null;
  const perArea = new Map(); // id → rolled-up stats, for the heat maps
  // `visibleCells`, not `visited`: a source switched off in the Type legend is
  // off the whole map, so it cannot be what lights a region either — a country
  // nothing visible remains in is a country you have not been to as far as this
  // picture is concerned. The two are the same Set unless something is hidden.
  for (const id of visibleCells) {
    const cid = areaOfCellMemo(kind, id);
    if (!cid) continue;
    if (isContinentKind) {
      const country = areaOfCellMemo('country', id);
      let seen = countriesIn.get(cid);
      if (!seen) countriesIn.set(cid, (seen = new Set()));
      seen.add(country);
    }
    litIds.add(cid);
    const stat = cellStatsOf(id, byType);
    let e = perArea.get(cid);
    // `near` stays 0: a whole region is its own neighbourhood, so it is read on
    // its own count rather than against the ring of hexes around it.
    if (!e) perArea.set(cid, (e = { hits: 0, time: 0, age: 0, near: 0, srcN: new Map() }));
    e.hits += stat.hits;
    if (stat.time > e.time) e.time = stat.time;
    if (stat.age && (!e.age || stat.age < e.age)) e.age = stat.age;
    // A whole country is colored by whichever app covers the most of it — by
    // ground, not by visits, which is the question the country level answers.
    if (byType && stat.own) {
      const src = slotOf.get(stat.own) ?? TYPE_MAX;
      e.srcN.set(src, (e.srcN.get(src) ?? 0) + 1);
    }
  }
  for (const e of perArea.values()) {
    let best = TYPE_MAX;
    let bestN = -1;
    for (const [src, n] of e.srcN ?? []) {
      if (n > bestN || (n === bestN && src < best)) {
        best = src;
        bestN = n;
      }
    }
    e.src = best;
  }
  return { litIds, perArea, countriesIn };
}

export function areaFeatures(kind, mode, fine, litIds, perArea, labels, heat) {
  if (heat) {
    const range = {
      maxHits: 1,
      hotHits: hotOf(perArea),
      // Areas get their own ladder: a country's first-seen is the earliest of
      // everything inside it, so a hundred countries spread quite differently
      // from the twenty thousand cells they are made of.
      ageStops: ageStopsOf(perArea),
      minTime: 0, maxTime: 0, minAge: 0, maxAge: 0,
    };
    for (const e of perArea.values()) {
      if (e.hits > range.maxHits) range.maxHits = e.hits;
      if (e.time) {
        if (!range.minTime || e.time < range.minTime) range.minTime = e.time;
        if (e.time > range.maxTime) range.maxTime = e.time;
      }
      if (e.age) {
        if (!range.minAge || e.age < range.minAge) range.minAge = e.age;
        if (e.age > range.maxAge) range.maxAge = e.age;
      }
    }
    const features = [];
    for (const [id, stat] of perArea) {
      const geometry = areaGeometry(kind, id, fine);
      if (geometry) {
        features.push({ type: 'Feature', properties: { k: 1, v: heat(stat, range) }, geometry });
      }
    }
    return { type: 'FeatureCollection', features: [...features, ...labels] };
  }

  const { fill, rings } = mergeAreas(kind, litIds, fine);
  const features = [];
  if (fill.length) {
    features.push({ type: 'Feature', properties: { k: 1 }, geometry: { type: 'MultiPolygon', coordinates: fill } });
  }
  if (rings.length) {
    features.push({ type: 'Feature', properties: { k: 2 }, geometry: { type: 'MultiLineString', coordinates: rings } });
  }
  return { type: 'FeatureCollection', features: [...features, ...labels] };
}
