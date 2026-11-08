// Render data for clients that have a map SDK but no JavaScript lattice.
import { createHash } from 'node:crypto';
import { cellStats, cellColorOf, HEAT_MODES } from '../src/coloring.js';
import { rollUp, finishRollUpSteps, storedUnder } from '../src/rollup.js';
import { cellCenter, colsOf, radiusOf, lngOf, latOf } from '../src/hexgrid.js';
import { sparseCell } from '../src/blob-shaping.js';

import { summarizeCells } from '../src/cell-info-data.js';

const facts = new WeakMap();
const MAX_ACCOUNTS = 8;
const MAX_VARIANTS = 4;
const cache = new Map();

export function forget(userId) {
  if (userId === undefined) cache.clear();
  else cache.delete(userId);
}

export function cellsOptions(query) {
  const level = Number(query.get('level') ?? 0);
  const mode = query.get('mode') ?? 'flat';
  const accent = query.get('accent') ?? '#60acff';
  const bbox = (query.get('bbox') ?? '-180,-85.051129,180,85.051129').split(',').map(Number);
  const hidden = [...new Set(query.getAll('hidden'))].sort();
  if (!Number.isInteger(level) || level < 0 || level > 5) throw new Error('level must be an integer from 0 to 5');
  if (!Object.hasOwn(HEAT_MODES, mode)) throw new Error('unknown colouring mode');
  if (!/^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/i.test(accent)) throw new Error('accent must be a hex colour');
  if (query.has('bbox') && query.get('bbox').split(',').some((part) => !part.trim())) throw new Error('bbox must contain four numbers');
  if (hidden.length > 100 || hidden.some((s) => s.length > 200)) throw new Error('too many or oversized hidden sources');
  if (bbox.length !== 4 || bbox.some((n) => !Number.isFinite(n)) ||
      Math.abs(bbox[0]) > 180 || Math.abs(bbox[2]) > 180 ||
      Math.abs(bbox[1]) > 85.051129 || Math.abs(bbox[3]) > 85.051129 || bbox[1] > bbox[3]) {
    throw new Error('bbox must be west,south,east,north in geographic coordinates');
  }
  return { level, mode, accent: accent.toLowerCase(), bbox, hidden, info: query.get('info') === '1' };
}

export function cellsTag(signature, options) {
  return 'render-cells:' + createHash('sha1').update(JSON.stringify([signature, options])).digest('base64url');
}

export function cells(userId, signature, supply, options) {
  let account = cache.get(userId);
  if (!account || account.signature !== signature) {
    account = { signature, variants: new Map() };
    cache.delete(userId);
    cache.set(userId, account);
    if (cache.size > MAX_ACCOUNTS) cache.delete(cache.keys().next().value);
  }
  const { level, mode, accent, bbox, hidden } = options;
  const key = JSON.stringify([mode === 'type', hidden]);
  let rolled = account.variants.get(key);
  if (!rolled) {
    const { cellIds, cellMeta } = account.input ??= supply();
    rolled = rollUp(cellIds, (id, byType) => cellStats(cellMeta.get(id), byType), {
      byType: mode === 'type', hidden: new Set(hidden),
    });
    for (const _ of finishRollUpSteps(rolled, mode === 'type')) { /* drain */ }
    account.variants.set(key, rolled);
    if (account.variants.size > MAX_VARIANTS) account.variants.delete(account.variants.keys().next().value);
  }
  const lit = rolled.litSets[level];
  const colorOf = cellColorOf(mode, accent, rolled.litRange[level]);
  const [west, south, east, north] = bbox;
  const rows = [];
  let summaries = facts.get(rolled);
  if (options.info && !summaries) facts.set(rolled, summaries = new Map());
  for (const e of lit.values()) {
    const [x, y] = cellCenter(level, e.col, e.row);
    // Canonical columns live in [0, WORLD); native maps use [-180, 180).
    const lng = ((lngOf(x) + 180) % 360) - 180;
    const lat = latOf(y);
    if (lat < south || lat > north || !(west <= east ? lng >= west && lng <= east : lng >= west || lng <= east)) continue;
    const cellKey = e.col + '/' + e.row;
    const row = [cellKey, x, y, colorOf(e), sparseCell(lit, colsOf(level), e.col, e.row)];
    if (options.info) {
      const factKey = level + '/' + cellKey;
      if (!summaries.has(factKey)) summaries.set(factKey, summarizeCells(storedUnder(rolled.litSets, level, cellKey), account.input.cellMeta));
      row.push(summaries.get(factKey));
    }
    rows.push(row);
  }
  return { level, radius: radiusOf(level), columns: ['key', 'x', 'y', 'color', 'sparse', ...(options.info ? ['info'] : [])], rows };
}
