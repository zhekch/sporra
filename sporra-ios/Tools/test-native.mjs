// Exercise the actual Swift networking code against an isolated, disposable server.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const temporary = await mkdtemp(path.join(tmpdir(), 'sporra-native-api-'));
const port = 3218;
const run = (command, args, options = {}) => new Promise((resolve, reject) => {
  const process = spawn(command, args, { stdio: 'inherit', ...options });
  process.on('error', reject);
  process.on('exit', code => code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`)));
});
let server;
let connectionServer;
try {
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/TrackCardNavigation.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/NativeDate.swift'),
    path.join(root, 'sporra-ios/Tools/TrackCardCheck.swift'), '-o', path.join(temporary, 'track-card-check')]);
  await run(path.join(temporary, 'track-card-check'), []);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/NativeDate.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/NativeTripPresentation.swift'),
    path.join(root, 'sporra-ios/Tools/TripListCheck.swift'), '-o', path.join(temporary, 'trip-list-check')]);
  await run(path.join(temporary, 'trip-list-check'), []);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/RecentSearchItems.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/ActivityChoices.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/NativeDate.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/NativeSearchPresentation.swift'),
    path.join(root, 'sporra-ios/Tools/RecentSearchCheck.swift'), '-o', path.join(temporary, 'recent-search-check')]);
  await run(path.join(temporary, 'recent-search-check'), []);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/ActivityChoices.swift'),
    path.join(root, 'sporra-ios/Tools/ActivityChoicesCheck.swift'), '-o', path.join(temporary, 'activity-choices-check')]);
  await run(path.join(temporary, 'activity-choices-check'), []);
  await run('xcrun', ['swiftc', '-emit-library', '-emit-module', '-module-name', 'SporraCore',
    path.join(root, 'sporra-ios/SporraCore/Sources/SporraCore/HexGrid.swift'),
    path.join(root, 'sporra-ios/SporraCore/Sources/SporraCore/CellGeometry.swift'),
    '-emit-module-path', path.join(temporary, 'SporraCore.swiftmodule'),
    '-o', path.join(temporary, 'libSporraCore.dylib')]);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    '-I', temporary, '-L', temporary, '-lSporraCore', '-Xlinker', '-rpath', '-Xlinker', temporary,
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/MapPlaceFacts.swift'),
    path.join(root, 'sporra-ios/Tools/MapPlaceCheck.swift'), '-o', path.join(temporary, 'map-place-check')]);
  await run(path.join(temporary, 'map-place-check'), [path.join(root, 'sporra-webserver/src/regions.json')]);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/MapRenderState.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/MapImageSwapState.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/MapFocusLayout.swift'),
    path.join(root, 'sporra-ios/Tools/MapRenderCheck.swift'), '-o', path.join(temporary, 'render-check')]);
  await run(path.join(temporary, 'render-check'), []);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/NativeRail.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/ActivityMapSelection.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/NativeLayerOrder.swift'),
    path.join(root, 'sporra-ios/Tools/NativeAPICheck.swift'), '-o', path.join(temporary, 'native-check')]);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Tools/OfflineAPICheck.swift'), '-o', path.join(temporary, 'offline-check')]);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Tools/ConnectionAPICheck.swift'), '-o', path.join(temporary, 'connection-check')]);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/CellViewportCache.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/MapPerformance.swift'),
    path.join(root, 'sporra-ios/Tools/CellViewportCheck.swift'), '-o', path.join(temporary, 'viewport-check')]);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/RegionSnapshotCache.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/MapPerformance.swift'),
    path.join(root, 'sporra-ios/Tools/RegionSnapshotCheck.swift'), '-o', path.join(temporary, 'region-check')]);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/ActivityDetailCache.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/MapPerformance.swift'),
    path.join(root, 'sporra-ios/Tools/ActivityDetailCheck.swift'), '-o', path.join(temporary, 'activity-detail-check')]);
  const activityRequests = new Map();
  const regionRequests = new Map();
  let sessionChecks = 0;
  connectionServer = createServer((request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Content-Type', 'application/json');
    if (request.url === '/api/me' && ++sessionChecks === 1) {
      setTimeout(() => response.end(JSON.stringify({ ok: true })), 2000);
      return;
    }
    if (request.url.startsWith('/api/render/activity?')) {
      const id = new URL(request.url, 'http://localhost').searchParams.get('id');
      const sequence = (activityRequests.get(id) ?? 0) + 1;
      activityRequests.set(id, sequence);
      setTimeout(() => response.end(JSON.stringify({ route: { id }, sequence, samples: [] })), 1000);
      return;
    }
    if (request.url.startsWith('/api/render/regions')) {
      const parameters = new URL(request.url, 'http://localhost').searchParams;
      const level = parameters.get('level');
      const sequence = (regionRequests.get(level) ?? 0) + 1;
      regionRequests.set(level, sequence);
      const reply = () => response.end(JSON.stringify({ type: 'FeatureCollection', features: [], infoFeatures: [],
        sequence, coarse: parameters.get('fine') === '0', geometryOnly: parameters.get('info') === '0', global: !parameters.has('bbox') }));
      if (level === '7' || (level === '6' && parameters.get('fine') === '0')) { setTimeout(reply, 750); return; }
      if (request.url.includes('fine=1')) setTimeout(reply, 2000);
      else reply();
      return;
    }
    if (request.url.startsWith('/api/render/cells')) {
      const reply = () => response.end(JSON.stringify({ level: 0, radius: 50, rows: [['origin', 0, 0, '#60acff', false]] }));
      if (request.url.includes('bbox=')) setTimeout(reply, 2000);
      else reply();
      return;
    }
    if (request.url === '/api/render/interrupted') { request.socket.destroy(); return; }
    if (request.url === '/api/render/error') {
      response.writeHead(500); response.end(JSON.stringify({ error: 'Render failed' })); return;
    }
    const reply = () => response.end(JSON.stringify({ ok: true }));
    if (request.url === '/api/render/slow') setTimeout(reply, 6000);
    else reply();
  });
  await new Promise(resolve => connectionServer.listen(0, '127.0.0.1', resolve));
  await run(path.join(temporary, 'activity-detail-check'), [
    `http://127.0.0.1:${connectionServer.address().port}`, path.join(temporary, 'activity-cache')]);
  await run(path.join(temporary, 'region-check'), [
    `http://127.0.0.1:${connectionServer.address().port}`, path.join(temporary, 'region-cache')]);
  await run(path.join(temporary, 'viewport-check'), [
    `http://127.0.0.1:${connectionServer.address().port}`, path.join(temporary, 'viewport-cache')]);
  await run(path.join(temporary, 'connection-check'), [
    `http://127.0.0.1:${connectionServer.address().port}`, path.join(temporary, 'connection-cache')]);
  await new Promise(resolve => connectionServer.close(resolve)); connectionServer = null;
  server = spawn(process.execPath, ['server/index.js'], {
    cwd: path.join(root, 'sporra-webserver'),
    env: { ...process.env, PORT: String(port), DB_PATH: path.join(temporary, 'test.db'), BACKUP_DIR: path.join(temporary, 'backups'), ALLOW_REGISTRATION: '1', UPDATE_CHECK: '0' },
    stdio: ['ignore', 'ignore', 'inherit'],
  });
  let ready = false;
  for (let i = 0; i < 80; i++) {
    try { await fetch(`http://127.0.0.1:${port}/api/health`); ready = true; break; }
    catch { await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  if (!ready) throw new Error('Disposable server did not start');
  await run(path.join(temporary, 'native-check'), [`http://127.0.0.1:${port}`, path.join(temporary, "cache")]);
  await run(path.join(temporary, 'offline-check'), [`http://127.0.0.1:${port}`, path.join(temporary, 'offline-cache'), 'seed']);
  const stopped = new Promise(resolve => server.once('exit', resolve));
  server.kill(); await stopped; server = null;
  await run(path.join(temporary, 'offline-check'), [`http://127.0.0.1:${port}`, path.join(temporary, 'offline-cache'), 'offline']);

} finally {
  if (connectionServer) await new Promise(resolve => connectionServer.close(resolve));
  if (server && server.exitCode === null) { const done = new Promise(resolve => server.once('exit', resolve)); server.kill(); await done; }
  await rm(temporary, { recursive: true, force: true });
}
