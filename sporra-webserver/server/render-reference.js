import { readFileSync } from 'node:fs';
import { terrainStyle, satelliteStyle } from '../src/basemap.js';
import { AIRPORT_GROUPS, airportLayers, loadAirports, airportGeoJson, describeAirportFeature } from '../src/airports.js';
import { randomPalette } from '../src/route-colors.js';
const styles = new Map();
const airportCollections = new Map();
export async function style(name) {
  if (!['terrain', 'satellite'].includes(name)) throw new Error('unknown basemap');
  if (!styles.has(name)) styles.set(name, (name === 'terrain' ? terrainStyle() : satelliteStyle()).catch(e => { styles.delete(name); throw e; }));
  return styles.get(name);
}
export async function reference(kind, origin, group = 'airline', index = null) {
  if (kind === 'airports' || kind === 'airport') {
    if (!AIRPORT_GROUPS.some(g => g.key === group)) throw new Error('unknown airport group');
    if (!airportCollections.has(group)) {
      const data = JSON.parse(readFileSync(new URL(`../src/airports-${group}.json`, import.meta.url)));
      await loadAirports([group], { [group]: data });
      const collection = airportGeoJson([group]);
      // Native hits need an exact identity: the location-notification endpoint
      // intentionally ignores helipads and may choose a nearby airline field.
      for (const f of collection.features) Object.assign(f.properties, {
        group, index: f.id, name: f.properties.n, code: f.properties.c || f.properties.i,
        city: f.properties.m, country: f.properties.y,
      });
      airportCollections.set(group, { ...collection, layers: airportLayers().filter(l => l.group === group) });
    }
    const collection = airportCollections.get(group);
    if (kind === 'airports') return collection;
    if (index === null || !/^\d+$/.test(String(index)) || !collection.features[Number(index)]) throw new Error('unknown airport');
    return describeAirportFeature(collection.features[Number(index)]);
  }
  if (kind !== 'rail') throw new Error('unknown reference overlay');
  const data = JSON.parse(readFileSync(new URL('../src/rail-style.json', import.meta.url)));
  const resolve = value => {
    if (Array.isArray(value)) {
      if (value[0] === 'global-state') return data.state[value[1]] ?? null;
      return value.map(resolve);
    }
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k,v]) => [k, resolve(v)]));
    if (typeof value === 'string' && value.startsWith('/api/')) return origin + value;
    return value;
  };
  // Symbol sprites use a multi-sprite extension; native lines work independently.
  return { sources: resolve(data.sources), layers: resolve(data.layers.filter(l => l.type === 'line')) };
}

export function activityPalette(keys) {
  if (!Array.isArray(keys) || keys.length > 256 || keys.some(k => typeof k !== 'string' || k.length > 200)) {
    throw new Error('invalid activity types');
  }
  const unique = [...new Set(keys)];
  const colors = randomPalette(unique.length);
  return Object.fromEntries(unique.map((key, i) => [key, colors[i]]));
}
