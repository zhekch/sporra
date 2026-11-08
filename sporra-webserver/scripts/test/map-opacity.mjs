import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { mapOpacityFor, readMapOpacities } from '../../src/map-opacity.js';

assert.equal(mapOpacityFor({}, 'flat', 0.3), 0.3);
for (const mode of ['visits', 'oldest', 'type']) {
  assert.equal(mapOpacityFor({}, mode, 0.5), 0.5);
}
const saved = JSON.parse(JSON.stringify({ flat: 1, visits: 0, oldest: 0.73 }));
assert.equal(mapOpacityFor(saved, 'flat', 0.3), 1);
assert.equal(mapOpacityFor(saved, 'visits', 0.5), 0);
assert.equal(mapOpacityFor(saved, 'oldest', 0.5), 0.73);
assert.equal(mapOpacityFor(saved, 'type', 0.5), 0.5);
// Explicit endpoints bypass legacy alpha and basemap multipliers.
assert.equal(mapOpacityFor(saved, 'flat', 0.39 * 0.2), 1);
assert.deepEqual(readMapOpacities({ flat: -2, visits: 3, oldest: '0.5', type: NaN }), { flat: 0, visits: 1 });
assert.deepEqual(readMapOpacities(null), {});
const main = readFileSync(new URL('../../src/main.js', import.meta.url), 'utf8');
assert.match(main, /mapOpacities: \{ \.\.\.mapOpacities \}/);
assert.match(main, /mapOpacities = readMapOpacities\(prefs.mapOpacities\)/);
assert.match(main, /localStorage.setItem\(MAP_OPACITIES_KEY, JSON.stringify\(mapOpacities\)\)/);
assert.match(main, /value: accent,\s+opacity: false/);
const html = readFileSync(new URL('../../index.html', import.meta.url), 'utf8');
assert.ok(html.indexOf('id="map-opacity"') > html.indexOf('id="color-row"'));
assert.match(html, /id="map-opacity" type="range" min="0" max="100"/);
console.log('Map opacity: defaults, endpoints, independent modes and persistence passed.');
