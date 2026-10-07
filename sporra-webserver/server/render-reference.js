import { technicalFilter, RAIL_GROUP_DEFAULTS } from '../src/rail-rules.js';
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
// UIKit's property bridge accepts hex colors, while CSS hsl/named colors can
// reach an uncaught native conversion error. Keep the same colors in hex form.
function nativeColor(value) {
  if (Array.isArray(value)) return value.map(v => nativeColor(v));
  if (typeof value !== 'string') return value;
  const named = { white: '#ffffff', black: '#000000', yellow: '#ffff00', red: '#ff0000' };
  if (named[value]) return nativeColor(named[value]);
  if (/^#[0-9a-f]{3}$/i.test(value)) return nativeColor('#' + [...value.slice(1)].map(c=>c+c).join(''));
  const hsl = /^hsl\(([-\d.]+),\s*([\d.]+)%,\s*([\d.]+)%\)$/.exec(value);
  if (hsl) {
    const h = (+hsl[1] % 360 + 360) % 360 / 360, s = +hsl[2]/100, l = +hsl[3]/100;
    const a = s * Math.min(l,1-l);
    const component = n => { const k = (n + h*12)%12; return Math.round(255*(l-a*Math.max(-1,Math.min(k-3,9-k,1)))).toString(16).padStart(2,'0'); };
    return nativeColor('#' + component(0) + component(8) + component(4));
  }
  const rgba = /^rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)%\)$/.exec(value);
  if (rgba) return ['rgba', +rgba[1], +rgba[2], +rgba[3], +rgba[4]/100];
  return value;
}

export async function reference(kind, origin, group = 'airline', index = null, options = {}) {
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
  const state = { ...data.state };
  if (options.native) {
    Object.assign(state, {
      sporraTechnical: !!options.technical,
      showConstructionInfrastructure: !!options.technical,
      showProposedInfrastructure: !!options.technical,
      showAbandonedInfrastructure: !!options.technical,
      showRazedInfrastructure: !!options.technical,
      theme: options.theme === 'light' ? 'light' : 'dark',
    });
  }
  const resolve = value => {
    if (Array.isArray(value)) {
      if (options.native && value[0] === 'feature-state' && value[1] === 'hover') return false;
      if (value[0] === 'global-state') return state[value[1]] ?? null;
      if (value[0] === 'literal') return value;
      const out = value.map(resolve);
      const literal = v => !Array.isArray(v) && (v === null || typeof v !== 'object');
      if (out[0] === 'boolean' && literal(out[1])) return typeof out[1] === 'boolean' ? out[1] : out[2];
      if (out[0] === 'to-boolean' && literal(out[1])) return !!out[1];
      if (out[0] === 'case') {
        for (let i = 1; i < out.length - 1; i += 2) {
          if (typeof out[i] !== 'boolean') return out;
          if (out[i]) return out[i + 1];
        }
        return out.at(-1);
      }
      if (['==','!=','<','<=','>','>='].includes(out[0]) && literal(out[1]) && literal(out[2])) {
        const [op,a,b] = out;
        return op === '==' ? a === b : op === '!=' ? a !== b : op === '<' ? a < b : op === '<=' ? a <= b : op === '>' ? a > b : a >= b;
      }
      return out;
    }
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k,v]) => [k, resolve(v)]));
    if (typeof value === 'string' && value.startsWith('/api/')) return origin + value;
    return value;
  };
  if (!options.native) return { sources: resolve(data.sources), layers: resolve(data.layers.filter(l => l.type === 'line')) };
  const layers = data.layers.map(layer => {
    const extra = technicalFilter(layer['source-layer']);
    const result = resolve({ ...layer, ...(extra ? { filter: ['all', ...(layer.filter ? [layer.filter] : []), extra] } : {}) });
    for (const key of Object.keys(result.paint ?? {})) if (key.endsWith('color')) result.paint[key] = nativeColor(result.paint[key]);
    if (result.layout?.['text-font']) result.layout['text-font'] = ['Open Sans Regular'];
    for (const part of ['icon', 'text']) {
      if (result.layout?.[`${part}-overlap`]) {
        result.layout[`${part}-allow-overlap`] = result.layout[`${part}-overlap`] === 'always';
        delete result.layout[`${part}-overlap`];
      }
    }
    return result;
  });
  return { sources: resolve(data.sources), layers, sprites: resolve(data.sprites),
    groups: data.groups.map(({ key,label }) => ({ key,label, enabled: RAIL_GROUP_DEFAULTS[key] ?? true })) };
}

export function activityPalette(keys) {
  if (!Array.isArray(keys) || keys.length > 256 || keys.some(k => typeof k !== 'string' || k.length > 200)) {
    throw new Error('invalid activity types');
  }
  const unique = [...new Set(keys)];
  const colors = randomPalette(unique.length);
  return Object.fromEntries(unique.map((key, i) => [key, colors[i]]));
}
