import { mercX, mercY, pointToCell, normCol, colsOf } from './hexgrid.js';

export function normalizeVisitDates(values) {
  if (!Array.isArray(values)) return [];
  const days = new Set();
  for (const value of values.slice(0, 100000)) {
    const d = typeof value === 'number' ? new Date(value * 1000)
      : typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) ? new Date(value + 'T00:00:00Z') : null;
    if (!d || !Number.isFinite(d.getTime()) || d.getUTCFullYear() < 1990 || d.getTime() > Date.now() + 86400000) continue;
    const day = d.toISOString().slice(0, 10);
    if (typeof value === 'string' && day !== value) continue;
    days.add(day);
  }
  return [...days].sort().reverse();
}

// Recover dates from saved geometry at measured vertices only. A route's time
// span is not evidence that every point along it was visited on every day.
export function routeVisitDates(routes) {
  const cells = new Map();
  for (const route of routes) {
    for (let s = 0; s < (route.geom?.length ?? 0); s++) {
      for (let i = 0; i < route.geom[s].length; i++) {
        const [lng, lat] = route.geom[s][i];
        const at = route.trace?.[s]?.[i]?.[1] || (route.firstAt && route.lastAt && Math.floor(route.firstAt / 86400) === Math.floor(route.lastAt / 86400) ? route.firstAt : 0);
        if (!at) continue;
        const [col, row] = pointToCell(0, mercX(lng), mercY(lat));
        const id = `0/${normCol(col, colsOf(0))}/${row}`;
        if (!cells.has(id)) cells.set(id, new Set());
        for (const day of normalizeVisitDates([at])) cells.get(id).add(day);
      }
    }
  }
  return cells;
}
