import assert from 'node:assert/strict';
import { reference } from '../../server/render-reference.js';
import { RAIL_GROUP_DEFAULTS } from '../../src/rail-rules.js';
const origin = 'https://example.test';
const normal = await reference('rail', origin, 'airline', null, {native:true});
const technical = await reference('rail', origin, 'airline', null, {native:true, technical:true, theme:'light'});
assert.deepEqual(new Set(normal.layers.map(l=>l.type)), new Set(['line','fill','symbol','circle']));
assert.equal(normal.groups.length, 6);
for (const g of normal.groups) assert.equal(g.enabled, RAIL_GROUP_DEFAULTS[g.key]);
assert.equal(normal.layers.length, technical.layers.length);
assert(!JSON.stringify(normal).includes('global-state'));
assert(!JSON.stringify(technical).includes('global-state'));
assert(normal.sprites.every(s=>s.url.startsWith(origin)));
const track = normal.layers.find(l=>l['source-layer'] === 'railway_line_high');
assert(JSON.stringify(track.filter).includes('proposed'));
assert(JSON.stringify(track.filter).includes('service'));
const enabled = technical.layers.find(l=>l.id===track.id);
assert.equal(enabled.filter.at(-1)[1], true);
assert.equal(track.filter.at(-1)[1], false);
for (const l of normal.layers) {
  assert(['visible','none',undefined].includes(l.layout?.visibility));
  if(l.layout?.['text-font']) assert.deepEqual(l.layout['text-font'],['Open Sans Regular']);
}
assert.equal(normal.layers.find(l=>l.id.endsWith('railway_text_km')).paint['text-color'], '#dbdadd');
assert(!JSON.stringify(normal.layers.map(l=>l.paint)).includes('hsl('));
const legacy = await reference('rail',origin);
assert(legacy.layers.every(l=>l.type==='line'));
console.log('Native railway groups, sprites, theme and technical filtering passed');
