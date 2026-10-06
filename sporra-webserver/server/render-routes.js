import { duplicateRoutes, routeSamples, recordedSeconds, formatDistance, formatDuration, totalLength, distanceByYear } from '../src/routes.js';
import { graphData } from '../src/route-graph.js';
import { metricCollection } from '../src/route-metric.js';
// Native clients consume the browser's palette and account preferences.
import { paletteFor } from '../src/route-colors.js';
import { hexOpaque, hexAlpha } from '../src/color-picker.js';

// Use the browser's preference rules; imports remain stored and individually accessible.
export function foldedActivities(routes) {
  const duplicates = duplicateRoutes(routes);
  return { routes: routes.filter(r => !duplicates.has(r.id)),
    duplicates: Object.fromEntries(duplicates), foldedCount: duplicates.size };
}

export function routeFeatures(routes, view = {}, stackIds = []) {
  const folded = foldedActivities(routes);
  routes = folded.routes;
  stackIds = [...new Set(stackIds.map(id => folded.duplicates[id] ?? id))];
  view = view && typeof view === 'object' ? view : {};
  const hidden = new Set(Array.isArray(view.hidden) ? view.hidden : []);
  const colors = view.colors ?? {};
  const rainbow = view.rainbow ? paletteFor(routes.map(r => r.id)) : new Map();
  const stack = new Set(stackIds);
  const stackColors = !view.rainbow ? paletteFor(stackIds) : new Map();
  const features = [];
  for (const r of routes) {
    if (stack.size && !stack.has(r.id)) continue;
    const sport = r.sport || '\u0000none';
    if (hidden.has(sport)) continue;
    const chosen = /^#[0-9a-f]{6}([0-9a-f]{2})?$/i.test(colors[sport] ?? '') ? colors[sport] : '#ff9147';
    for (const segment of r.geom ?? []) {
      if (segment.length < 2) continue;
      features.push({ type: 'Feature', id: r.id,
        properties: { id: r.id, name: r.name, sport: r.sport ?? '', color: stackColors.get(r.id) ?? rainbow.get(r.id) ?? hexOpaque(chosen), alpha: hexAlpha(chosen) },
        geometry: { type: 'LineString', coordinates: segment } });
    }
  }
  return { type: 'FeatureCollection', features };
}

export function activityData(route) {
  const samples = routeSamples(route.geom, route.trace);
  const duration = recordedSeconds(route);
  return { route, samples,
    summary: { distance: formatDistance(route.lengthM), duration: formatDuration(duration), averageSpeed: duration ? (route.lengthM / duration * 3.6).toFixed(1) + ' km/h' : null },
    graphs: { speed: graphData(samples, 'speed'), elev: graphData(samples, 'elev') },
    lines: { speed: metricCollection(samples, 'speed'), elev: metricCollection(samples, 'elev') },
  };
}

export function activityStats(routes) {
  const folded = foldedActivities(routes);
  routes = folded.routes;
  const longest = routes.reduce((best, r) => !best || r.lengthM > best.lengthM ? r : best, null);
  return { ...folded, distance: formatDistance(totalLength(routes)),
    duration: formatDuration(routes.reduce((sum, r) => sum + recordedSeconds(r), 0)),
    longest: longest ? { name: longest.name, distance: formatDistance(longest.lengthM) } : null,
    years: distanceByYear(routes).map(([year, value]) => ({ year, value, label: formatDistance(value) })),
  };
}
