import { readFileSync } from 'node:fs';
import { terrainStyle, satelliteStyle } from '../src/basemap.js';
const styles = new Map();
export async function style(name) {
  if (!['terrain', 'satellite'].includes(name)) throw new Error('unknown basemap');
  if (!styles.has(name)) styles.set(name, (name === 'terrain' ? terrainStyle() : satelliteStyle()).catch(e => { styles.delete(name); throw e; }));
  return styles.get(name);
}
export function reference(kind, origin) {
  if (kind === 'airports') {
    const data = JSON.parse(readFileSync(new URL('../src/airports-airline.json', import.meta.url)));
    return { type: 'FeatureCollection', features: (data.rows ?? data.airports).map((r, i) => ({ type: 'Feature', id: i,
      properties: { name: r[3], code: r[4] || r[5], city: r[6], country: r[7] }, geometry: { type: 'Point', coordinates: [r[0], r[1]] } })) };
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
