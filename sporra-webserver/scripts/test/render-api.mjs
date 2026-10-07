import { prepareLinkImport } from '../../server/import-links.js';
import { search as nativeSearch } from '../../server/render-geography.js';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const PORT = 3199;
const BASE = `http://127.0.0.1:${PORT}`;

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

const dir = await mkdtemp(path.join(tmpdir(), 'visited-map-render-'));
const server = spawn(process.execPath, ['server/index.js'], {
  cwd: ROOT,
  env: { ...process.env, PORT: String(PORT), DB_PATH: path.join(dir, 'test.db'), ALLOW_REGISTRATION: '1' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let serverErr = '';
server.stderr.on('data', (b) => {
  serverErr += b.toString();
});

async function waitForServer() {
  for (let i = 0; i < 60; i++) {
    try {
      await fetch(`${BASE}/api/me`);
      return true;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  return false;
}

let cookie = '';
async function api(method, url, body, headers = {}) {
  const res = await fetch(`${BASE}${url}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(cookie ? { Cookie: cookie } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const setCookie = res.headers.get('set-cookie');
  if (setCookie) cookie = setCookie.split(';')[0];
  const text = await res.text();
  return {
    status: res.status,
    etag: res.headers.get('etag'),
    cacheControl: res.headers.get('cache-control'),
    text,
    body: text ? JSON.parse(text) : null,
  };
}


try {
  if (!(await waitForServer())) throw new Error(serverErr);
  check((await api('GET', '/api/render/cells')).status === 401, 'requires authentication');
  await api('POST', '/api/register', { username: 'rendertest', password: 'a-long-enough-pw' });
  await api('POST', '/api/cells/import', { source: 'gpx', cells: [['0/0/0',100,200,3,5],['0/1/0',150,250,9,10],['0/625481/0',300,400,2,4]] });
  const { cells, cellsOptions, forget } = await import('../../server/render.js');
  const { cellStats, cellColorOf } = await import('../../src/coloring.js');
  const { rollUp, finishRollUpSteps } = await import('../../src/rollup.js');
  const { cellCenter } = await import('../../src/hexgrid.js');
  const raw = (await api('GET', '/api/cells')).body;
  const cellMeta = new Map();
  for (const [id, src, addedAt, firstAt, lastAt, hits, fixes] of raw.rows) {
    const list = cellMeta.get(id) ?? [];
    list.push({source:raw.sources[src],addedAt,firstAt,lastAt,hits,fixes}); cellMeta.set(id,list);
  }
  const input = { cellIds:[...cellMeta.keys()],cellMeta };
  for (const mode of ['flat','visits','oldest','type']) {
    const rolled = rollUp(input.cellIds,(id,t)=>cellStats(cellMeta.get(id),t),{byType:mode==='type'});
    for (const _ of finishRollUpSteps(rolled,mode==='type')) {}
    for (let level=0;level<=5;level++) {
      const result=await api('GET',`/api/render/cells?mode=${mode}&level=${level}`);
      const color=cellColorOf(mode,'#60acff',rolled.litRange[level]);
      const expected=[...rolled.litSets[level].values()].map(e=>[e.col+'/'+e.row,...cellCenter(level,e.col,e.row),color(e)]);
      check(result.status===200 && JSON.stringify(result.body.rows.map(r=>r.slice(0,4)))===JSON.stringify(expected),`${mode} level ${level} matches browser`);
    }
  }
  const first=await api('GET','/api/render/cells');
  check((await api('GET','/api/render/cells',undefined,{'If-None-Match':first.etag})).status===304,'revalidates');
  check((await api('GET','/api/render/cells?accent=%23ff0000',undefined,{'If-None-Match':first.etag})).status===200,'accent changes validator');
  check((await api('GET','/api/render/cells?hidden=gpx')).body.rows.length===0,'hidden source');
  check((await api('GET','/api/render/cells?bbox=170,-1,-170,1')).body.rows.length===0,'date-line viewport');
  check((await api('GET','/api/render/cells?bbox=-1,-1,1,1')).body.rows.length===3,'canonical columns wrap to Greenwich');
  check(first.body.rows.find(r=>r[0]==='0/0')[4]===false,'wrapped sparse neighbours');
  for (const q of ['level=6','level=x','mode=bad','accent=red','bbox=1,2,3','bbox=0,30,1,20','bbox=0,0,Infinity,1']) check((await api('GET','/api/render/cells?'+q)).status===400,'rejects '+q);
  await api('POST','/api/cells/mutate',{add:['0/10/0']});
  check((await api('GET','/api/render/cells',undefined,{'If-None-Match':first.etag})).status===200,'edit invalidates');

  const gpx = '<?xml version="1.0"?><gpx><trk><name>Zurich walk</name><trkseg><trkpt lat="47.37" lon="8.54"><time>2024-08-10T09:00:00Z</time></trkpt><trkpt lat="47.371" lon="8.542"><time>2024-08-10T09:01:00Z</time></trkpt><trkpt lat="47.372" lon="8.544"><time>2024-08-10T09:02:00Z</time></trkpt></trkseg></trk></gpx>';
  const beforePreview = await api('GET', '/api/cells');
  const routesBeforePreview = await api('GET', '/api/routes');
  const preview = await api('POST', '/api/import/file', {name:'walk.gpx', text:gpx, preview:true, source:'preview-test'});
  check(preview.status === 200 && preview.body.preview && preview.body.imported > 0 && preview.body.routes > 0 && preview.body.sources[0] === 'preview-test', 'import preview reports shared cells, routes and chosen source');
  check((await api('GET', '/api/cells')).text === beforePreview.text && (await api('GET', '/api/routes')).text === routesBeforePreview.text, 'preview leaves ground and routes unchanged');
  const noRoutesPreview = await api('POST', '/api/import/file', {name:'walk.gpx', text:gpx, preview:true, includeRoutes:false});
  check(noRoutesPreview.body.imported === preview.body.imported && noRoutesPreview.body.routes === 0, 'preview respects route exclusion without dropping visited ground');
  const noRoutesImport = await api('POST', '/api/import/file', {name:'walk.gpx', text:gpx, includeRoutes:false, source:'ground-only'});
  check(noRoutesImport.status === 200 && noRoutesImport.body.routes === 0 && (await api('GET', '/api/routes')).text === routesBeforePreview.text, 'ground-only import saves no activity routes');
  const imported = await api('POST', '/api/import/file', {name:'walk.gpx', text:gpx});
  check(imported.status===200 && imported.body.imported>0 && imported.body.routes>0, 'raw GPX imports shared cells and activity geometry');
  const linkPoints = [{lng:8.54,lat:47.37,t:1723280400},{lng:8.542,lat:47.371,t:1723280460},{lng:8.544,lat:47.372,t:1723280520}];
  const links = await prepareLinkImport({links:'https://www.komoot.com/tour/123456?share_token=secret'}, async ref => {
    check(ref.id === '123456' && ref.shareToken === 'secret', 'link importer retains private-tour share token');
    return {tour:{name:'Komoot walk'},points:linkPoints,tracks:[{name:'Komoot walk',sport:'Walking',segments:[linkPoints],firstAt:linkPoints[0].t,lastAt:linkPoints[2].t}]};
  });
  check(links.batches[0].cells.length > 0 && links.batches[0].routes.length > 0 && links.batches[0].routes[0].link.includes('share_token=secret'), 'link import uses shared ground and activity derivation with canonical tour link');
  check((await api('POST','/api/import/link',{links:'https://example.com/arbitrary.gpx'})).status === 400, 'link import rejects unsupported link providers');
  check((await api('GET','/api/sources')).body.sources.every(s => typeof s.label === 'string'), 'source lists contain shared readable names');
  const nativeRoutes = await api('GET', '/api/render/routes');
  check(nativeRoutes.status === 200 && nativeRoutes.body.features.length > 0, 'native routes return geometry with web appearance');
  const sport = nativeRoutes.body.features[0].properties.sport || '\u0000none';
  const activityId = nativeRoutes.body.features[0].properties.id;
  const activity = await api('GET', '/api/render/activity?id=' + activityId);
  check(activity.status === 200 && activity.body.graphs.speed && activity.body.samples.length > 1, 'activity API returns speed graph and aligned samples');
  check((await api('GET', '/api/render/activity?id=' + activityId, undefined, {'If-None-Match':activity.etag})).status === 304, 'activity graph revalidates');
  check((await api('GET', '/api/render/activity?id=bad')).status === 400, 'invalid activity id is refused');
  check((await api('GET', '/api/render/activity-stats')).body.years.length > 0, 'activity statistics include annual distance readings');

  await api('POST', '/api/prefs', { prefs: { routeView: { colors: { [sport]: '#ff000080' } } } });
  const colored = await api('GET', '/api/render/routes', undefined, { 'If-None-Match': nativeRoutes.etag });
  check(colored.status === 200 && colored.body.features[0].properties.color === '#ff0000' && colored.body.features[0].properties.alpha === 128/255, 'activity preferences invalidate route rendering and preserve alpha');
  await api('POST', '/api/prefs', { prefs: { routeView: { hidden: [sport] } } });
  check((await api('GET', '/api/render/routes')).body.features.length === 0, 'hidden activity categories leave native map');
  await api('POST', '/api/prefs', { prefs: {} });
  const info = await api('GET', '/api/render/at?lng=8.54&lat=47.37&level=0');
  check(info.status===200 && info.body.visited && info.body.hits>0, 'tap resolves imported visit facts');
  const { pointToCell, normCol, colsOf, mercX, mercY } = await import('../../src/hexgrid.js');
  for (let level = 0; level < 6; level++) {
    const [col, row] = pointToCell(level, mercX(8.54), mercY(47.37));
    const key = `${normCol(col, colsOf(level))}/${row}`;
    const prefetched = await api('GET', `/api/render/cells?level=${level}&info=1`);
    const live = await api('GET', `/api/render/at?lng=8.54&lat=47.37&level=${level}`);
    const facts = prefetched.body.rows.find(r => r[0] === key)?.[5];
    check(facts && ['hits','addedAt','firstAt','lastAt'].every(k => facts[k] === live.body[k]), `prefetched level ${level} visit facts match live tap`);
  }
  const { trackFC } = await import('../../src/track-data.js');
  const points = [{lng:0,lat:0,at:1},{lng:1,lat:1,at:2},{lng:2,lat:2,at:2},{lng:3,lat:3,at:200000},{lng:4,lat:4,at:200001}];
  const track = trackFC(points);
  check(track.features.filter(f => f.geometry.type === 'Point').length === 5 && track.features.filter(f => f.geometry.type === 'LineString').length === 2, 'shared trip geometry retains dots and recording gaps');
  const dayTrack = await api('GET', '/api/render/track?day=2024-08-10');
  check(dayTrack.status === 200 && dayTrack.body.track.features.length > 0, 'day track has drawable geometry');
  const trips = (await api('GET','/api/trips')).body.trips;
  check(trips.length > 0, 'fixture derives a trip');
  if (trips.length) {
    const tripTrack = await api('GET','/api/render/track?trip='+trips[0].id);
    check(tripTrack.status === 200 && tripTrack.body.track.features.filter(f => f.geometry.type === 'Point').length === trips[0].spots.length, 'trip spots become yellow markers');
    await api('POST', '/api/prefs', { prefs: { tripNames: { [trips[0].id]: 'Parity journey' } } });
    const named = await api('GET', '/api/search?q=Parity%20journey');
    check(named.body.results.some(r => r.kind === 'trip' && r.name === 'Parity journey'), 'search uses account trip names');
    await api('POST', '/api/prefs', { prefs: { tripNames: { [trips[0].id]: 'Parity journey' }, hiddenTrips: [trips[0].id] } });
    const hiddenTrip = await api('GET', '/api/search?q=Parity%20journey', undefined, { 'If-None-Match': named.etag });
    check(hiddenTrip.status === 200 && !hiddenTrip.body.results.some(r => r.id === trips[0].id && r.kind === 'trip'), 'hidden trip invalidates search validator and disappears');
    await api('POST', '/api/prefs', { prefs: {} });

  }

  check((await api('GET','/api/render/track?trip=missing')).status === 404, 'missing trip refused');
  check((await api('GET','/api/render/track?day=bad')).status === 400, 'invalid day refused');
  check((await api('GET','/api/render/track?day=2024-08-10&trip=anything')).status === 400, 'ambiguous track refused');

  for (const level of [6,7,8]) {
    const r = await api('GET', '/api/render/regions?level='+level);
    check(r.status===200 && r.body.features.some(f=>f.properties.k===1), 'region level '+level+' has fills');
    const prefetched = await api('GET', '/api/render/regions?info=1&level='+level);
    check(prefetched.body.infoFeatures?.some(f => f.properties.visited && f.properties.firstAt), 'region level '+level+' prefetches visit facts');
    const live = await api('GET', '/api/render/at?lng=8.54&lat=47.37&level='+level);
    const cached = prefetched.body.infoFeatures?.find(f => f.properties.area.id === live.body.area?.id)?.properties;
    check(live.body.geometry && cached?.covered > 0 && cached.covered === live.body.covered && cached.coveredPct === live.body.coveredPct, 'region level '+level+' caches matching coverage and selection geometry');
    const repeat = await api('GET', '/api/render/regions?level='+level, undefined, {'If-None-Match':r.etag});
    check(repeat.status===304, 'region level '+level+' revalidates');
  }
  // Exercise the LOD path without spending a test's network on the public
  // boundary provider. Detailed fixtures add a midpoint to each coarse edge.
  const geo = await import('../../server/render-geography.js');
  const regionData = await import('../../src/regions.js');
  await geo.prime();
  const fresh = (await api('GET','/api/cells')).body;
  const meta = new Map();
  for (const [id, source, addedAt, firstAt, lastAt, hits, fixes] of fresh.rows) {
    const rows = meta.get(id) ?? [];
    rows.push({source:fresh.sources[source], addedAt, firstAt, lastAt, hits, fixes});
    meta.set(id,rows);
  }
  const fineInput = {cellIds:[...meta.keys()], cellMeta:meta};
  const fineOptions = {...cellsOptions(new URLSearchParams('info=1&bbox=8,47,9,48')),level:6,fine:true};
  let fineReads = 0;
  const detail = geometry => {
    const polygons = geometry.type === 'Polygon' ? [geometry.coordinates] : geometry.coordinates;
    return {type:'MultiPolygon',coordinates:polygons.map(poly=>poly.map(ring=>ring.flatMap((p,i)=>i+1<ring.length?[p,[(p[0]+ring[i+1][0])/2,(p[1]+ring[i+1][1])/2]]:[p])))};
  };
  const supplyFine = async iso => {
    fineReads++;
    return {regions:Object.fromEntries(regionData.regionsOf(iso).map(r=>[r.id,detail(r.geometry)]))};
  };
  const coarse = await geo.regions(fineInput,{...fineOptions,fine:false});
  const sharp = await geo.regions(fineInput,fineOptions,supplyFine);
  check(fineReads>0 && JSON.stringify(sharp.infoFeatures[0].geometry)!==JSON.stringify(coarse.infoFeatures[0].geometry), 'visible regions request detailed LOD and replace coarse geometry');
  const readsAfterFine = fineReads;
  await geo.regions(fineInput,fineOptions,supplyFine);
  check(fineReads===readsAfterFine, 'detailed boundary requests are reused');
  await geo.regions(fineInput,{...fineOptions,bbox:[-170,-20,-160,-10]},supplyFine);
  check(fineReads===readsAfterFine, 'offscreen regions do not fetch boundary detail');
  const ranked = await nativeSearch('Zurich',
    [{ id: 'route-rank', name: 'Zurich walk' }],
    [{ id: 'trip-rank', name: 'Zurich holiday', start: 1723280400, end: 1723366800 }]);
  check(ranked[0]?.id === 'trip-rank' && ranked[1]?.id === 'route-rank' && ranked.slice(2).length > 0 && ranked.slice(2).every(r => r.kind !== 'trip' && r.kind !== 'route'), 'search ranks trips, routes, then gazetteer places');
  const place = await api('GET','/api/search?q=Z%C3%BCrich');
  check(place.status===200 && place.body.results.length>0, 'search answers gazetteer results');
  check((await api('GET','/api/locale/en')).status===200,'English locale is available');
  const paint = await api('POST','/api/render/brush',{level:0,size:1,action:'paint',points:[[8.6,47.4]]});
  check(paint.status===200 && paint.body.undo.remove.length===1, 'single-cell brush paints exactly one cell');
  const erase = await api('POST','/api/render/brush',{level:0,size:1,action:'erase',points:[[8.6,47.4]]});
  check(erase.status===200 && erase.body.undo.rows.length===1, 'erase captures provenance for undo');
  await api('POST','/api/cells/restore',{rows:erase.body.undo.rows});
  check((await api('GET','/api/render/at?lng=8.6&lat=47.4&level=0')).body.visited, 'restore recovers erased cell');
  const beforeClear = await api('GET','/api/cells');
  const clear = await api('POST','/api/render/region-clear',{lng:8.54,lat:47.37});
  check(clear.status===200 && clear.body.undo.rows.length>0, 'region clear uses shared cell attribution');
  await api('POST','/api/cells/restore',{rows:clear.body.undo.rows});
  check((await api('GET','/api/cells')).body.rows.length===beforeClear.body.rows.length,'region undo restores provenance');
  for (const body of [{points:[]},{level:6,size:1,action:'paint',points:[[0,0]]},{level:0,size:1,action:'paint',points:[[0,0],[90,0]]}]) check((await api('POST','/api/render/brush',body)).status===400,'invalid or enormous stroke is refused');
  const { readFileSync } = await import('node:fs');
  const { airportGeoJson, airportLayers, loadAirports, describeAirportFeature } = await import('../../src/airports.js');
  for (const group of ['airline', 'airfields', 'helipads', 'closed']) {
    const tuples = JSON.parse(readFileSync(new URL(`../../src/airports-${group}.json`, import.meta.url)));
    await loadAirports([group], { [group]: tuples });
    const airports = await api('GET', `/api/render/reference?kind=airports&group=${group}`);
    const expected = airportGeoJson([group]);
    check(airports.status === 200 && airports.body.features.length === expected.features.length && airports.body.features.every((f, i) => JSON.stringify(f.geometry) === JSON.stringify(expected.features[i].geometry) && Object.entries(expected.features[i].properties).every(([k,v]) => f.properties[k] === v)), `${group} airport points and details match the web dataset`);
    const card = await api('GET', `/api/render/reference?kind=airport&group=${group}&index=0`);
    check(JSON.stringify(card.body) === JSON.stringify(describeAirportFeature(expected.features[0])), `${group} airport card uses exact web facts and links`);
    check(JSON.stringify(airports.body.layers) === JSON.stringify(airportLayers().filter(l => l.group === group)), `${group} native zoom and kind rules match the web`);
    check((await api('GET', `/api/render/reference?kind=airports&group=${group}`, undefined, {'If-None-Match': airports.etag})).status === 304, `${group} reference revalidates`);
  }
  check((await api('GET', '/api/render/reference?kind=airports&group=../../secret')).status === 400, 'unknown airport groups are rejected');
  for (const index of ['', '-1', '1.5', '999999', 'bad']) check((await api('GET', '/api/render/reference?kind=airport&index=' + index)).status === 400, 'invalid airport identity refused');
  const defaultAirports = await api('GET', '/api/render/reference?kind=airports');
  check(defaultAirports.text === (await api('GET', '/api/render/reference?kind=airports&group=airline')).text, 'default reference remains airline airports');
  const paletteKeys = ['Run', 'Ride', '\u0000none'];
  const randomColors = await api('POST', '/api/render/activity-palette', {keys:paletteKeys});
  const { ROUTE_PALETTE } = await import('../../src/route-colors.js');
  check(randomColors.status === 200 && paletteKeys.every(k => ROUTE_PALETTE.includes(randomColors.body.colors[k])) && new Set(Object.values(randomColors.body.colors)).size === paletteKeys.length, 'random activity colors use distinct shared palette entries including the blank sport');
  for (const keys of [null, [42], Array(257).fill('Run'), ['x'.repeat(201)]]) check((await api('POST', '/api/render/activity-palette', {keys})).status === 400, 'invalid palette input rejected');
  const savedCookie = cookie; cookie = '';
  check((await api('POST', '/api/render/activity-palette', {keys:paletteKeys})).status === 401, 'palette requires authentication');
  cookie = savedCookie;
  check((await api('GET','/api/render/reference?kind=rail')).body.layers.every(l=>l.type==='line'),'rail native layers use line geometry');
  forget(); let reads=0; const supply=()=>{reads++;return input;}; const opts=cellsOptions(new URLSearchParams());
  cells(1,'a',supply,opts);cells(1,'a',supply,{...opts,bbox:[-1,-1,1,1]});check(reads===1,'viewport reuses rollup');
  cells(1,'b',supply,opts);check(reads===2,'signature rebuilds');
  const dateId='0/312741/0';
  const dateInput={cellIds:[dateId],cellMeta:new Map([[dateId,[{source:'manual'}]]])};
  const crossing={...opts,bbox:[170,-1,-170,1]};
  check(cells(2,'a',()=>dateInput,crossing).rows.length===1,'crossing viewport includes date-line cell');
  check(cells(3,'a',()=>({cellIds:[],cellMeta:new Map()}),opts).rows.length===0,'account caches are isolated');
  check(cells(1,'b',supply,{...opts,bbox:[40,40,41,41]}).rows.length===0,'empty viewport');
  const saved = (await api('GET', '/api/routes?geom=1')).body.routes[0];
  await api('POST', '/api/routes', { routes: [{...saved, key:'render-stack-second', name:'Second overlap', firstAt:saved.firstAt+86400, lastAt:saved.lastAt+86400}] });
  const stackedRoutes = (await api('GET', '/api/routes')).body.routes;
  const stackIds = stackedRoutes.map(r => r.id);
  const stack = await api('GET', '/api/render/routes?' + stackIds.map(id => 'stack='+id).join('&'));
  check(new Set(stack.body.features.map(f => f.properties.color)).size === 2, 'overlap stack uses distinct shared web colours');
  const isolatedStack = await api('GET', '/api/render/routes?stack='+activityId);
  check(isolatedStack.body.features.every(f => f.properties.id === activityId), 'stack draws only chosen activities');
  check((await api('GET','/api/render/routes?stack=bad')).status === 400, 'invalid stack selection is refused');
  await api('POST', '/api/register', {username:'renderother', password:'a-long-enough-pw'});
  check((await api('GET', '/api/render/activity?id=' + activityId)).status === 404, 'activity detail is isolated to its owner');
  check((await api('GET', '/api/render/routes')).body.features.length === 0, 'native activity geometry is account isolated');


} catch(e) { check(false,'test run',e.stack); }
finally { server.kill();await rm(dir,{recursive:true,force:true}); }
console.log(`render API: ${pass} ok, ${fail} failed`);process.exit(fail?1:0);
