import { parseKomootUrls, fetchTour, tourUrl } from '../src/komoot.js';
import { pointsToCells } from '../src/locations.js';
import { buildRoutes } from '../src/routes.js';

export async function prepareLinkImport(body, fetch = fetchTour) {
  if (typeof body.links !== 'string' || body.links.length > 8000) throw new Error('Paste Komoot tour or share links.');
  const refs = parseKomootUrls(body.links);
  if (!refs.length || refs.length > 10) throw new Error('Paste between one and ten Komoot tour or share links.');
  const points = [], routes = [], files = [];
  for (const ref of refs) {
    const result = await fetch(ref);
    points.push(...result.points);
    files.push(result.tour.name || `Tour ${ref.id}`);
    if (body.includeRoutes !== false) routes.push(...buildRoutes(result.tracks, { source: 'komoot', fileName: result.tour.name }).map(route => ({ ...route, link: tourUrl(ref) })));
  }
  points.sort((a, b) => a.t - b.t);
  return { batches: [{ source: 'komoot', cells: pointsToCells(points), routes }], sources: ['komoot'], files };
}
