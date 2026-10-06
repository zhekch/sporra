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
  const imported = await api('POST', '/api/import/file', {name:'walk.gpx', text:gpx});
  check(imported.status===200 && imported.body.imported>0 && imported.body.routes>0, 'raw GPX imports shared cells and activity geometry');
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
  for (const level of [6,7,8]) {
    const r = await api('GET', '/api/render/regions?level='+level);
    check(r.status===200 && r.body.features.some(f=>f.properties.k===1), 'region level '+level+' has fills');
    const repeat = await api('GET', '/api/render/regions?level='+level, undefined, {'If-None-Match':r.etag});
    check(repeat.status===304, 'region level '+level+' revalidates');
  }
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
  check((await api('GET','/api/render/reference?kind=airports')).body.features.length>0,'airports are native GeoJSON');
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
  await api('POST', '/api/register', {username:'renderother', password:'a-long-enough-pw'});
  check((await api('GET', '/api/render/activity?id=' + activityId)).status === 404, 'activity detail is isolated to its owner');
  check((await api('GET', '/api/render/routes')).body.features.length === 0, 'native activity geometry is account isolated');


} catch(e) { check(false,'test run',e.stack); }
finally { server.kill();await rm(dir,{recursive:true,force:true}); }
console.log(`render API: ${pass} ok, ${fail} failed`);process.exit(fail?1:0);
