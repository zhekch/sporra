import assert from 'node:assert/strict';
import { routeFeatures } from '../../server/render-routes.js';
import { paletteFor } from '../../src/route-colors.js';
const routes = [
  { id: 1, name: 'Walk', sport: 'Walking', geom: [[[8,47],[8.01,47.01]], [[8.02,47.02]]] },
  { id: 2, name: 'Ride', sport: 'Cycling', geom: [[[8,47],[8.1,47.1]]] },
  { id: 3, name: 'Other', sport: '', geom: [[[8,47],[8.1,47.1]]] },
];
const styled = routeFeatures(routes, { colors: { Walking: '#ff000080', Cycling: 'invalid' } });
assert.equal(styled.features.length, 3, 'single-point segments do not render');
assert.equal(styled.features[0].properties.color, '#ff0000');
assert.equal(styled.features[0].properties.alpha, 128 / 255);
assert.equal(styled.features[1].properties.color, '#ff9147', 'invalid colour uses web default');
const hidden = routeFeatures(routes, { hidden: ['Walking', '\u0000none'] });
assert.deepEqual(hidden.features.map(f => f.id), [2]);
const rainbow = routeFeatures(routes, { rainbow: true, colors: { Walking: '#ff000080' } });
const expected = paletteFor(routes.map(r => r.id));
for (const f of rainbow.features) assert.equal(f.properties.color, expected.get(f.id), 'same per-route palette as browser');
assert.equal(rainbow.features[0].properties.alpha, 128 / 255, 'rainbow preserves activity opacity');
assert.equal(new Set(rainbow.features.map(f => f.properties.color)).size, 3);
console.log('native route rendering: activity colours, alpha, visibility and browser palette passed');
const { activityData } = await import('../../server/render-routes.js');
const { routeSamples } = await import('../../src/routes.js');
const { metricCollection } = await import('../../src/route-metric.js');
const measured = { id: 4, name: 'Measured walk', firstAt: 1000, lastAt: 1900, lengthM: 1000,
  geom: [[[8,47], [8.001,47], [8.002,47]], [[8.01,47], [8.011,47]]],
  trace: [[[100,1000],[120,1300],[110,1600]], [[null,1800],[150,1900]]] };
const activity = activityData(measured);
assert.deepEqual(activity.samples, routeSamples(measured.geom, measured.trace), 'native samples match web readings');
assert.equal(activity.graphs.elev.runs.length, 2, 'missing heights and recording gaps split graph runs');
assert.equal(activity.graphs.elev.min, 100);
assert.equal(activity.graphs.elev.max, 150);
assert.equal(activity.graphs.speed.byTime, true);
assert.deepEqual(activity.lines.speed, metricCollection(activity.samples, 'speed'), 'map metric colouring matches web');
assert.equal(activity.summary.duration, '15 min');
const withoutTime = activityData({...measured, trace: [[[100,0],[120,0],[110,0]], [[null,0],[150,0]]]});
assert.equal(withoutTime.graphs.speed, null, 'undated activity has no invented speeds');
assert.equal(withoutTime.graphs.elev.byTime, false, 'distance axis is used without timestamps');
assert.equal(activityData({...measured, trace: null}).graphs.elev, null, 'missing heights have no invented elevation');
console.log('native activity graphs: shared samples, gap handling, axes, summaries and map colouring passed');
const { activityStats } = await import('../../server/render-routes.js');
const stats = activityStats([
  {...measured, firstAt: Date.UTC(2023, 6, 1) / 1000, lastAt: Date.UTC(2023, 6, 1) / 1000 + 900},
  {...measured, id: 5, firstAt: Date.UTC(2024, 6, 1) / 1000, lastAt: Date.UTC(2024, 6, 1) / 1000 + 900, lengthM: 2000},
  {...measured, id: 6, firstAt: 0, lastAt: 0, lengthM: 500},
]);
assert.deepEqual(stats.years.map(y => [y.year, y.value]), [[2023,1000], [2024,2000]], 'distance chart excludes undated routes');
assert.equal(stats.distance, '3.5 km', 'total still includes undated distance');
assert.equal(stats.duration, '30 min', 'duration only includes credible clocks');
assert.equal(stats.longest.distance, '2.0 km');
console.log('native activity statistics: annual distance, totals and duration passed');
