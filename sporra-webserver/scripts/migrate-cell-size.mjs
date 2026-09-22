// Rewrite every stored cell onto the 50 m grid.
//
// The ids in the database were computed on the old lattice (~0.9 km at the
// equator, ~600 m where this map actually is). They are not a finer version of
// themselves: subdividing a painted hex would colour the fields beside the
// road. What this does instead, in the order the points were worth trusting:
//
//   1. Saved routes — the workout and ride lines, still in the database at
//      about a 6 m tolerance — are rasterised straight onto the new grid.
//   2. Geotagged photos from the Mac's library, if it will give them up.
//      The coordinates were folded into cells and thrown away; a 600 m hex
//      is not a place to invent a doorway. If the library cannot be read,
//      the old photo cells are dropped and the next sync from the app fills
//      them, because that sync replaces the whole source.
//   3. Everything else is a chain of old hexes. Thin chains are matched to
//      the road or the railway they follow. A filled patch is the streets
//      inside those hexes, and nothing past them. A chain the network cannot
//      explain — a flight, a ferry, a trail that was never mapped — keeps
//      the line of its old centres, drawn thin.
//
// One shot. A second run refuses, because the ids it would read are already
// the new ones and it would "refine" them again. The database is copied into
// backups/ before anything is written.
//
//   node scripts/migrate-cell-size.mjs

import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

import { BASE_COLS } from '../src/hexgrid.js';
import { pointsToCells } from '../src/locations.js';
import { loadCountries } from '../src/countries.js';
import { loadRegions } from '../src/regions.js';
import { computeStats } from '../src/stats.js';
import {
  cellsInside,
  chainTrace,
  chooseNetwork,
  classify,
  matchTrace,
  newCellId,
  newCenterLngLat,
  oldCellId,
  oldCenterLngLat,
  rasterize,
  rasterizeSegments,
  traceLength,
  traceSpeed,
} from './grid-migrate.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DB_PATH = process.env.DB_PATH || path.join(ROOT, 'data.db');
const CACHE = path.join(ROOT, 'cache', 'osm-match');
const META = 'grid_base_cols';
const TILE = 0.25;
const MIN_TILE = 0.0625;

// iPhone and Timeline were real GPS, just quantized. They go before anything
// painted by hand, so a later corridor inherits the line instead of guessing
// a second street beside it.
const COARSE_FIRST = ['iphone', 'home-assistant', 'google-timeline', 'snapchat', 'manual'];
const PHOTO_SOURCE = 'apple-photos';

// Paths and footways are left out. A 0.25° alpine tile of them is tens of
// thousands of ways and a minute of Overpass, and a hike with no mapped road
// already falls back to the line of the old centres. Track stays, for the
// gravel road that is the only thing through a valley.
const HIGHWAYS = 'motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street|pedestrian|track';
const RAILWAYS = 'rail|light_rail|subway|tram|narrow_gauge|disused|abandoned';

const ENDPOINTS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
];

const now = () => Math.floor(Date.now() / 1000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let fetchedTiles = 0;
let failedTiles = 0;
let tilesWithWays = 0;

// Two at a time. One is polite and slow across a few hundred tiles; four,
// which a split used to fire at once, is how a public Overpass starts
// answering 429.
let inFlight = 0;
const slotWaiters = [];
function takeSlot() {
  if (inFlight < 2) {
    inFlight++;
    return Promise.resolve();
  }
  return new Promise((resolve) => slotWaiters.push(resolve));
}
function releaseSlot() {
  inFlight--;
  const next = slotWaiters.shift();
  if (next) {
    inFlight++;
    next();
  }
}

function tileKey(s, w, size) {
  return `${s.toFixed(4)}_${w.toFixed(4)}_${size.toFixed(4)}`;
}

async function overpass(query) {
  await takeSlot();
  let lastErr = null;
  try {
  for (let attempt = 0; attempt < 5; attempt++) {
    if (attempt) await sleep(1500 * attempt);
    const url = ENDPOINTS[attempt % ENDPOINTS.length];
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': 'Sporra/0.101 (+https://github.com/zhekch/sporra; personal one-time grid migration)',
        },
        body: `data=${encodeURIComponent(query)}`,
        signal: AbortSignal.timeout(120_000),
      });
      if (res.status === 429 || res.status === 504 || res.status === 502) {
        lastErr = new Error(`${url} ${res.status}`);
        await sleep(4000 * (attempt + 1));
        continue;
      }
      if (!res.ok) {
        lastErr = new Error(`${url} ${res.status} ${(await res.text()).slice(0, 200)}`);
        await sleep(2000);
        continue;
      }
      return await res.json();
    } catch (e) {
      lastErr = e;
      await sleep(2000 * (attempt + 1));
    }
  }
  throw lastErr ?? new Error('overpass failed');
  } finally {
    releaseSlot();
  }
}

function waysFromOverpass(json) {
  const out = [];
  for (const el of json.elements ?? []) {
    if (el.type !== 'way' || !el.geometry || el.geometry.length < 2) continue;
    const railway = el.tags?.railway ?? '';
    const kind = RAILWAYS.split('|').includes(railway) ? 'rail' : 'road';
    out.push({
      id: el.id,
      kind,
      coords: el.geometry.map((g) => [g.lon, g.lat]),
    });
  }
  return out;
}

// A few tiles, not every tile. Holding the whole of Europe's roads at once
// is what ran the process out of memory after the matching had already
// finished, and the database write never got its turn.
const TILE_CACHE_MAX = 8;
const tileCache = new Map();

function rememberTile(key, ways) {
  if (tileCache.has(key)) tileCache.delete(key);
  tileCache.set(key, ways);
  while (tileCache.size > TILE_CACHE_MAX) {
    const oldest = tileCache.keys().next().value;
    tileCache.delete(oldest);
  }
  return ways;
}

async function loadTile(s, w, size) {
  const key = tileKey(s, w, size);
  if (tileCache.has(key)) {
    const ways = tileCache.get(key);
    rememberTile(key, ways);
    return ways;
  }
  const file = path.join(CACHE, `${key}.json`);
  if (existsSync(file)) {
    const parsed = JSON.parse(readFileSync(file, 'utf8'));
    const ways = parsed.split
      ? (await Promise.all(parsed.kids.map(([cs, cw, csize]) => loadTile(cs, cw, csize)))).flat()
      : parsed;
    if (ways.length) tilesWithWays++;
    return rememberTile(key, ways);
  }

  const query = `[out:json][timeout:90];
(
  way["highway"~"^(${HIGHWAYS})$"](${s},${w},${s + size},${w + size});
  way["railway"~"^(${RAILWAYS})$"](${s},${w},${s + size},${w + size});
);
out geom;`;
  try {
    const ways = waysFromOverpass(await overpass(query));
    writeFileSync(file, JSON.stringify(ways));
    fetchedTiles++;
    if (ways.length) tilesWithWays++;
    console.log(`  tile ${s.toFixed(2)},${w.toFixed(2)} ${size}° → ${ways.length} ways`);
    return rememberTile(key, ways);
  } catch (e) {
    if (size > MIN_TILE + 1e-9) {
      const h = size / 2;
      const kids = [
        [s, w, h], [s, w + h, h], [s + h, w, h], [s + h, w + h, h],
      ];
      console.log(`  tile ${s.toFixed(2)},${w.toFixed(2)} ${size}° split (${e.message ?? e})`);
      writeFileSync(file, JSON.stringify({ split: true, kids }));
      const ways = (await Promise.all(kids.map(([cs, cw, csize]) => loadTile(cs, cw, csize)))).flat();
      return rememberTile(key, ways);
    }
    failedTiles++;
    console.warn(`  tile ${s.toFixed(2)},${w.toFixed(2)} failed: ${e.message ?? e}`);
    return rememberTile(key, []);
  }
}

function tilesCovering(s, w, n, e) {
  const out = [];
  const lat0 = Math.floor(s / TILE);
  const lat1 = Math.floor((n - 1e-9) / TILE);
  const lng0 = Math.floor(w / TILE);
  const lng1 = Math.floor((e - 1e-9) / TILE);
  for (let i = lat0; i <= lat1; i++) {
    for (let j = lng0; j <= lng1; j++) out.push([i * TILE, j * TILE]);
  }
  return out;
}

async function waysIn(s, w, n, e) {
  const seen = new Set();
  const ways = [];
  for (const [ts, tw] of tilesCovering(s, w, n, e)) {
    for (const way of await loadTile(ts, tw, TILE)) {
      if (seen.has(way.id)) continue;
      let hit = false;
      for (const [lng, lat] of way.coords) {
        if (lat >= s && lat <= n && lng >= w && lng <= e) { hit = true; break; }
      }
      if (!hit) continue;
      seen.add(way.id);
      ways.push(way);
    }
  }
  return ways;
}

function bboxOf(points, pad = 0.008) {
  let s = 90, n = -90, w = 180, e = -180;
  for (const p of points) {
    const lat = p.lat ?? p[1];
    const lng = p.lng ?? p[0];
    if (lat < s) s = lat;
    if (lat > n) n = lat;
    if (lng < w) w = lng;
    if (lng > e) e = lng;
  }
  return [s - pad, w - pad, n + pad, e + pad];
}

function span(ids, old) {
  let first = 0, last = 0, hits = 1, added = Infinity;
  for (const id of ids) {
    const s = old.get(id);
    if (!s) continue;
    if (s.first > 0 && (!first || s.first < first)) first = s.first;
    if (s.last > last) last = s.last;
    if ((s.hits || 1) > hits) hits = s.hits;
    if (s.added < added) added = s.added;
  }
  return { first, last, hits, fixes: 0, added: Number.isFinite(added) ? added : now() };
}

/**
 * Rows keyed by cell and source. `addHits` is for two real visits (two rides
 * through one cell). Inheriting a coarse source onto a line that is already
 * drawn takes the wider date range and the larger visit count — summing would
 * count one stay once per 50 m cell.
 */
function absorb(rows, cellId, source, stats, addHits) {
  const key = `${cellId}\0${source}`;
  const prev = rows.get(key);
  if (!prev) {
    rows.set(key, {
      first: stats.first || 0,
      last: stats.last || 0,
      hits: stats.hits || 1,
      fixes: stats.fixes || 0,
      added: stats.added || now(),
    });
    return;
  }
  const firsts = [prev.first, stats.first].filter((t) => t > 0);
  prev.first = firsts.length ? Math.min(...firsts) : 0;
  prev.last = Math.max(prev.last || 0, stats.last || 0);
  prev.hits = addHits ? prev.hits + (stats.hits || 1) : Math.max(prev.hits, stats.hits || 1);
  prev.fixes = addHits ? prev.fixes + (stats.fixes || 0) : Math.max(prev.fixes, stats.fixes || 0);
  prev.added = Math.min(prev.added, stats.added || prev.added);
}

function coverOf(ids) {
  const covered = new Map();
  for (const id of ids) {
    const c = newCenterLngLat(id);
    if (!c) continue;
    const old = oldCellId(c[0], c[1]);
    let set = covered.get(old);
    if (!set) covered.set(old, (set = new Set()));
    set.add(id);
  }
  return covered;
}

function mergeCover(into, ids) {
  for (const [old, set] of coverOf(ids)) {
    let dest = into.get(old);
    if (!dest) into.set(old, (dest = new Set()));
    for (const id of set) dest.add(id);
  }
}

function readPhotos() {
  const swift = path.join(ROOT, 'scripts', 'photo-coords.swift');
  const bin = '/tmp/sporra-photo-coords';
  const compiled = spawnSync('swiftc', [
    '-O', '-framework', 'Photos', '-framework', 'CoreLocation', '-framework', 'Foundation',
    swift, '-o', bin,
  ], { encoding: 'utf8', timeout: 180_000 });
  if (compiled.status !== 0) {
    console.warn(`photos: could not compile the reader\n${(compiled.stderr || '').slice(0, 400)}`);
    return null;
  }
  const run = spawnSync(bin, [], { encoding: 'utf8', timeout: 300_000, maxBuffer: 64 * 1024 * 1024 });
  if (run.status !== 0) {
    console.warn(`photos: library not readable (${(run.stderr || '').trim().slice(0, 300)})`);
    return null;
  }
  const points = [];
  for (const line of run.stdout.split('\n')) {
    if (!line.trim()) continue;
    try {
      const p = JSON.parse(line);
      if (Number.isFinite(p.lat) && Number.isFinite(p.lng)) points.push({ lat: p.lat, lng: p.lng, t: p.t || 0 });
    } catch { /* a torn line is not a photograph */ }
  }
  return points;
}

async function buildUser(cellRows, routeRows, photoPoints) {
  const bySource = new Map();
  for (const r of cellRows) {
    let m = bySource.get(r.source);
    if (!m) bySource.set(r.source, (m = new Map()));
    m.set(r.cell_id, {
      first: r.first_at || 0,
      last: r.last_at || 0,
      hits: r.hits || 1,
      fixes: 0,
      added: r.added_at || now(),
    });
  }

  const rows = new Map();
  const covered = new Map();
  const report = { roadKm: 0, railKm: 0, plainKm: 0, routes: 0, routeCells: 0, photos: 0 };

  const routeSources = new Set();
  for (const route of routeRows) {
    let geom;
    try { geom = JSON.parse(route.geom); } catch { continue; }
    const ids = rasterizeSegments(geom);
    if (!ids.size) continue;
    routeSources.add(route.source);
    report.routes++;
    report.routeCells += ids.size;
    const stats = {
      first: route.first_at || 0,
      last: route.last_at || 0,
      hits: 1,
      fixes: 0,
      added: route.added_at || now(),
    };
    for (const id of ids) absorb(rows, id, route.source, stats, true);
    mergeCover(covered, ids);
  }

  // A workout cell the simplified line never touched — a very short one, or
  // a point the gap cutter kept. The centre of its old hex is as much as the
  // row still knows. It does not count as explaining the hex: one dot must
  // not stop the corridor around it being matched.
  for (const source of routeSources) {
    const old = bySource.get(source);
    if (!old) continue;
    for (const [id, stats] of old) {
      if (covered.has(id)) continue;
      const c = oldCenterLngLat(id);
      if (!c) continue;
      absorb(rows, newCellId(c[0], c[1]), source, { ...stats, fixes: 0 }, false);
    }
  }

  if (photoPoints && bySource.has(PHOTO_SOURCE)) {
    const cells = pointsToCells(photoPoints);
    const added = now();
    for (const c of cells) {
      absorb(rows, c.id, PHOTO_SOURCE, {
        first: c.first, last: c.last, hits: c.hits, fixes: c.fixes, added,
      }, true);
    }
    report.photos = photoPoints.length;
  }

  const coarse = [];
  for (const source of COARSE_FIRST) if (bySource.has(source) && !routeSources.has(source)) coarse.push(source);
  for (const source of bySource.keys()) {
    if (source === PHOTO_SOURCE || routeSources.has(source) || coarse.includes(source)) continue;
    coarse.push(source);
  }

  for (const source of coarse) {
    const old = bySource.get(source);
    for (const [id, stats] of old) {
      const have = covered.get(id);
      if (!have) continue;
      for (const nid of have) absorb(rows, nid, source, stats, false);
    }
    const pending = [...old.keys()].filter((id) => !covered.has(id));
    if (!pending.length) continue;
    const { city, chains, specks } = classify(pending);
    console.log(`  ${source}: ${pending.length} hexes → ${chains.length} chains, ${city.length} town, ${specks.length} specks`);

    let n = 0;
    for (const chain of chains) {
      n++;
      if (n % 25 === 0) console.log(`    ${source} chain ${n}/${chains.length}`);
      const trace = chainTrace(chain).map((p) => ({ ...p, t: old.get(p.id)?.first || old.get(p.id)?.last || 0 }));
      if (trace.length < 2) continue;
      const lengthM = traceLength(trace);
      const [s, w, north, e] = bboxOf(trace);
      const ways = await waysIn(s, w, north, e);
      const chosen = chooseNetwork(
        matchTrace(trace, ways.filter((way) => way.kind === 'road')),
        matchTrace(trace, ways.filter((way) => way.kind === 'rail')),
        { lengthM, speedMps: traceSpeed(trace) },
      );
      const coords = chosen ? chosen.coords : trace.map((p) => [p.lng, p.lat]);
      if (!chosen) report.plainKm += lengthM / 1000;
      else if (chosen.kind === 'rail') report.railKm += lengthM / 1000;
      else report.roadKm += lengthM / 1000;
      const ids = rasterize(coords);
      const fallback = span(chain, old);
      for (const id of ids) {
        const c = newCenterLngLat(id);
        const stats = (c && old.get(oldCellId(c[0], c[1]))) || fallback;
        absorb(rows, id, source, stats, false);
      }
      mergeCover(covered, ids);
    }

    for (const id of specks) {
      const c = oldCenterLngLat(id);
      if (!c) continue;
      const ways = await waysIn(c[1] - 0.01, c[0] - 0.01, c[1] + 0.01, c[0] + 0.01);
      const ids = new Set();
      const only = new Set([id]);
      for (const way of ways) for (const nid of cellsInside(way.coords, only)) ids.add(nid);
      const stats = old.get(id);
      if (!ids.size) {
        absorb(rows, newCellId(c[0], c[1]), source, stats, false);
        continue;
      }
      for (const nid of ids) absorb(rows, nid, source, stats, false);
      mergeCover(covered, ids);
    }

    if (city.length) {
      // Town cells are scattered — one list for a whole account — so the box
      // around all of them is a continent. Group by tile and only fetch the
      // ground a filled hex actually sits on.
      const want = new Set(city);
      const ids = new Set();
      const groups = new Map();
      for (const id of city) {
        const c = oldCenterLngLat(id);
        if (!c) continue;
        const key = `${Math.floor(c[1] / TILE)},${Math.floor(c[0] / TILE)}`;
        let bucket = groups.get(key);
        if (!bucket) groups.set(key, (bucket = []));
        bucket.push(c);
      }
      for (const centres of groups.values()) {
        const [s, w, north, e] = bboxOf(centres.map((c) => ({ lng: c[0], lat: c[1] })), 0.01);
        const ways = await waysIn(s, w, north, e);
        for (const way of ways) for (const nid of cellsInside(way.coords, want)) ids.add(nid);
      }
      const fallback = span(city, old);
      if (!ids.size) {
        for (const id of city) {
          const c = oldCenterLngLat(id);
          if (c) absorb(rows, newCellId(c[0], c[1]), source, old.get(id) || fallback, false);
        }
      } else {
        for (const id of ids) {
          const c = newCenterLngLat(id);
          const stats = (c && old.get(oldCellId(c[0], c[1]))) || fallback;
          absorb(rows, id, source, stats, false);
        }
        mergeCover(covered, ids);
      }
      console.log(`    ${source} town → ${ids.size || city.length} cells`);
    }
  }

  return { rows, report };
}

function backup() {
  mkdirSync(path.join(ROOT, 'backups'), { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const dest = path.join(ROOT, 'backups', `before-50m-${stamp}.db`);
  const r = spawnSync('sqlite3', [DB_PATH, `.backup ${dest}`], { encoding: 'utf8' });
  if (r.status !== 0 || !existsSync(dest)) {
    throw new Error(`backup failed: ${r.stderr || r.stdout || 'no file'}`);
  }
  console.log(`backup → ${dest}`);
  return dest;
}

const db0 = new DatabaseSync(DB_PATH, { readOnly: true });
const existing = db0.prepare('SELECT value FROM meta WHERE key = ?').get(META);
const cellCount = db0.prepare('SELECT COUNT(*) AS n FROM cell_sources').get().n;
if (existing?.value === String(BASE_COLS)) {
  console.log(`already on the ${BASE_COLS}-column grid (${cellCount} rows). Nothing to do.`);
  process.exit(0);
}
if (existing && existing.value !== String(BASE_COLS)) {
  console.error(`database says ${existing.value} columns; this code wants ${BASE_COLS}. Refusing.`);
  process.exit(1);
}
if (!cellCount) {
  console.log('no cells to migrate.');
  process.exit(0);
}

const users = db0.prepare('SELECT id, username FROM users').all();
const perUser = [];
for (const user of users) {
  perUser.push({
    user,
    cells: db0.prepare(`
      SELECT cell_id, source, added_at, first_at, last_at, hits, fixes
      FROM cell_sources WHERE user_id = ?
    `).all(user.id),
    routes: db0.prepare(`
      SELECT source, added_at, first_at, last_at, geom FROM routes WHERE user_id = ?
    `).all(user.id),
  });
}
const prefs = db0.prepare('SELECT user_id, prefs FROM user_prefs').all();
db0.close();

// The library is this Mac's. It belongs to whichever account already had
// photo cells — a seed account with none does not inherit someone else's
// pictures. Two accounts with photo cells: the larger one is the library.
const photoUsers = perUser
  .map((u) => ({ id: u.user.id, n: u.cells.filter((c) => c.source === PHOTO_SOURCE).length }))
  .filter((u) => u.n > 0)
  .sort((a, b) => b.n - a.n);
const photoOwner = photoUsers[0]?.id ?? null;

console.log(`reading photos for user ${photoOwner ?? '(none had photo cells)'}…`);
const photoPoints = photoOwner ? readPhotos() : null;
if (photoPoints) console.log(`  ${photoPoints.length} geotagged`);
else if (photoOwner) console.log('  skipped — old photo cells will be dropped, not guessed');

mkdirSync(CACHE, { recursive: true });
backup();

const db = new DatabaseSync(DB_PATH);
db.exec('PRAGMA busy_timeout = 8000');
db.exec('PRAGMA journal_mode = WAL');
// A previous run died after creating this and before the swap. Those rows
// are not the map; the live table is still the old grid.
db.exec('DROP TABLE IF EXISTS cell_sources_next');
db.exec(`CREATE TABLE cell_sources_next (
  user_id INTEGER NOT NULL,
  cell_id TEXT NOT NULL,
  source TEXT NOT NULL,
  added_at INTEGER NOT NULL,
  first_at INTEGER NOT NULL DEFAULT 0,
  last_at INTEGER NOT NULL DEFAULT 0,
  hits INTEGER NOT NULL DEFAULT 1,
  fixes INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, cell_id, source)
)`);
const ins = db.prepare(`
  INSERT INTO cell_sources_next(user_id, cell_id, source, added_at, first_at, last_at, hits, fixes)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
`);

// The what's-new baseline only reports growth. Leave it where it was and the
// next open announces a few hundred thousand places nobody travelled to.
// Taking the larger of the old snapshot and the new totals means a drop in
// km² — the hexes were fatter than the roads — is not news either.
const countries = JSON.parse(readFileSync(path.join(ROOT, 'src', 'countries.json'), 'utf8'));
const regions = JSON.parse(readFileSync(path.join(ROOT, 'src', 'regions.json'), 'utf8'));
await Promise.all([loadCountries(countries), loadRegions(regions)]);
const prefsByUser = new Map(prefs.map((p) => [p.user_id, p.prefs]));
const FIELDS = ['cells', 'km2', 'countries', 'regions', 'days', 'streakDays', 'workouts'];
const prefWrites = [];

for (const u of perUser) {
  console.log(`\n${u.user.username}: ${u.cells.length} old rows, ${u.routes.length} routes`);
  const points = u.user.id === photoOwner ? photoPoints : null;
  const { rows, report } = await buildUser(u.cells, u.routes, points);
  console.log(
    `  → ${rows.size} rows, routes ${report.routeCells} cells from ${report.routes} lines, `
    + `road ${report.roadKm.toFixed(0)} km, rail ${report.railKm.toFixed(0)} km, `
    + `unmatched ${report.plainKm.toFixed(0)} km, photos ${report.photos}`,
  );
  // The roads are on disk. Dropping them here is what keeps one account's
  // cells from sitting on top of every tile the previous account fetched.
  tileCache.clear();

  const raw = prefsByUser.get(u.user.id);
  if (raw) {
    let body;
    try { body = JSON.parse(raw); } catch { body = null; }
    if (body) {
      const meta = new Map();
      for (const [key, stats] of rows) {
        const cut = key.indexOf('\0');
        const cellId = key.slice(0, cut);
        const source = key.slice(cut + 1);
        const entry = {
          source, addedAt: stats.added, firstAt: stats.first, lastAt: stats.last,
          hits: stats.hits, fixes: stats.fixes,
        };
        const list = meta.get(cellId);
        if (list) list.push(entry);
        else meta.set(cellId, [entry]);
      }
      const stats = await computeStats(meta.keys(), meta);
      const fresh = {
        cells: stats.cells,
        km2: stats.km2,
        countries: stats.countries?.length ?? 0,
        regions: stats.regions?.length ?? 0,
        days: stats.days,
        streakDays: stats.streakDays,
        workouts: body.whatsNewSeen?.workouts ?? 0,
      };
      const prev = body.whatsNewSeen && typeof body.whatsNewSeen === 'object' ? body.whatsNewSeen : {};
      const seen = {};
      for (const k of FIELDS) seen[k] = Math.max(Number(fresh[k]) || 0, Number(prev[k]) || 0);
      body.whatsNewSeen = seen;
      prefWrites.push([JSON.stringify(body), u.user.id]);
      console.log(`${u.user.username}: ${stats.cells} cells, ${stats.km2.toFixed(1)} km², ${stats.countries.length} countries`);
    }
  }

  db.exec('BEGIN');
  try {
    for (const [key, stats] of rows) {
      const cut = key.indexOf('\0');
      ins.run(
        u.user.id, key.slice(0, cut), key.slice(cut + 1),
        stats.added, stats.first, stats.last, stats.hits, stats.fixes,
      );
    }
    db.exec('COMMIT');
  } catch (e) {
    try { db.exec('ROLLBACK'); } catch { /* already closed */ }
    throw e;
  }
}

if (failedTiles > 0 && tilesWithWays === 0) {
  db.exec('DROP TABLE IF EXISTS cell_sources_next');
  console.error('Overpass failed every tile and none came back with a road. Nothing was written; run it again.');
  process.exit(1);
}

db.exec('BEGIN');
try {
  for (const [body, userId] of prefWrites) {
    db.prepare('UPDATE user_prefs SET prefs = ? WHERE user_id = ?').run(body, userId);
  }
  db.exec('DELETE FROM cell_sources');
  db.exec('INSERT INTO cell_sources SELECT * FROM cell_sources_next');
  db.exec('DROP TABLE cell_sources_next');
  db.prepare('INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    .run(META, String(BASE_COLS));
  db.exec('COMMIT');
} catch (e) {
  try { db.exec('ROLLBACK'); } catch { /* already closed */ }
  try { db.exec('DROP TABLE IF EXISTS cell_sources_next'); } catch { /* the rollback undid it */ }
  throw e;
}

db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
db.close();

console.log(`\ndone. tiles fetched ${fetchedTiles}, failed ${failedTiles}. grid ${BASE_COLS}.`);
