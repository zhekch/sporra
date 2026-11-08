import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { pointsToCells } from '../../src/locations.js';
import { normalizeVisitTimes, withRouteVisitTimes } from '../../src/visit-dates.js';
import { buildTrips, dayDetail, activeDays, dayKey } from '../../src/trips.js';
import { trackData } from '../../src/track-data.js';
import { parseCellsBuffer, fillCells } from '../../src/cells-load.js';
import { readFileSync } from 'node:fs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const time = s => Date.parse(s) / 1000;
const start = time('2026-07-24T07:00:00Z');
const locations = [8.17, 8.34, 8.54];
// Four passes through the same three cells, deliberately out of storage order.
const points = [0, 1, 2, 2, 1, 0, 0, 1, 2, 2, 1, 0].map((i, n) => ({ lat: 47.4, lng: locations[i], t: start + n * 3600 }));
const cells = pointsToCells([...points].reverse());
assert.equal(cells.reduce((n, c) => n + c.visitTimes.length, 0), 12);
assert.deepEqual(normalizeVisitTimes([start + .5, start, start, '2026-07-24', NaN, Infinity, 0, Date.now() / 1000 + 999999]), [start, start + .5]);
const meta = new Map(cells.map(c => [c.id, [{ source: 'phone', firstAt: c.first, lastAt: c.last, hits: c.hits, visitTimes: c.visitTimes }]]));
const [trip] = buildTrips(meta, [], { home: null });
assert.deepEqual(trip.points.map(p => p.at), points.map(p => p.t), 'intermediate return journeys retain chronological order');
assert.equal(trip.spots.length, 3, 'many samples still summarize three places');
assert.equal(dayDetail(dayKey(start), [trip], [], meta).points.length, 12);
const lines = trackData(trip).track.features.filter(f => f.geometry.type === 'LineString');
const crossings = lines.flatMap(f => f.geometry.coordinates.slice(1).map((p, i) => [f.geometry.coordinates[i], p])).filter(([a,b]) => (a[0] < 8.4) !== (b[0] < 8.4));
assert.equal(crossings.length, 4, 'two out-and-back journeys cross the valley four times');
const first = cells[0];
const middle = start + 86400;
const middleMeta = new Map([[first.id, [{ source:'phone', firstAt:start, lastAt:start + 2*86400, visitTimes:[middle, middle+1] }]]]);
assert.equal(activeDays(middleMeta, []).get(dayKey(middle)).cells, 1, 'intermediate days are visible without inflating cell counts');
assert.equal(dayDetail(dayKey(middle), [], [], middleMeta).points.length, 2);
const legacy = new Map([[first.id, [{source:'phone', firstAt:start, lastAt:start+2*86400}]]]);
const route = {source:'phone', geom:[[[points[points.length-1].lng,47.4]]], trace:[[[null,middle]]]};
const enriched = withRouteVisitTimes(legacy, [route]);
assert.deepEqual(enriched.get(first.id)[0].visitTimes, [middle], 'saved traces recover actual intermediate timestamps');
assert.equal(legacy.get(first.id)[0].visitTimes, undefined, 'recovery leaves source metadata unchanged');
assert.equal(withRouteVisitTimes(new Map(), [route]).size, 0, 'cleared cells are not resurrected');
assert.equal(withRouteVisitTimes(legacy, [{...route, trace:[]}]).get(first.id)[0].visitTimes, undefined, 'untimed tracks invent no timestamps');
const body = {sources:['phone'], rows:[[first.id,0,start,first.first,first.last,first.hits,first.fixes,first.visitDates,first.visitTimes]]};
for (const worker of [false,true]) {
  const buffer = new TextEncoder().encode(JSON.stringify(body)).buffer;
  let parsed;
  if (worker) {
    const self={postMessage:m=>parsed=m};
    new Function('self', readFileSync(path.join(ROOT,'src/cells-worker.js'),'utf8'))(self);
    self.onmessage({data:{id:1,buffer}});
  } else parsed=parseCellsBuffer(buffer);
  const loaded = new Map();
  for (const _ of fillCells(parsed,new Set(),loaded));
  assert.deepEqual(loaded.get(first.id)[0].visitTimes,first.visitTimes,'worker and fallback retain all timestamp values');
}

const dir = await mkdtemp(path.join(tmpdir(),'sporra-visit-times-test-'));
const dbPath=path.join(dir,'test.db');
// Start from the old schema: startup must widen it without replacing rows.
const oldDb=new DatabaseSync(dbPath);
oldDb.exec('CREATE TABLE cell_sources(user_id INTEGER NOT NULL, cell_id TEXT NOT NULL, source TEXT NOT NULL, added_at INTEGER NOT NULL, first_at INTEGER NOT NULL DEFAULT 0, last_at INTEGER NOT NULL DEFAULT 0, hits INTEGER NOT NULL DEFAULT 1, fixes INTEGER NOT NULL DEFAULT 0, visit_dates TEXT NOT NULL DEFAULT \'[]\', PRIMARY KEY(user_id,cell_id,source))');
oldDb.close();
const port=3237;
let cookie=''; let output='';
const server=spawn(process.execPath,['server/index.js'],{cwd:ROOT,env:{...process.env,PORT:String(port),DB_PATH:dbPath,BACKUP_DIR:path.join(dir,'backups'),ALLOW_REGISTRATION:'1'},stdio:['ignore','pipe','pipe']});
server.stdout.on('data',b=>output+=b); server.stderr.on('data',b=>output+=b);
async function api(method,url,body,headers={}) {
  const res=await fetch(`http://127.0.0.1:${port}${url}`,{method,headers:{'Content-Type':'application/json',Cookie:cookie,...headers},body:body===undefined?undefined:JSON.stringify(body)});
  if(res.headers.get('set-cookie')) cookie=res.headers.get('set-cookie').split(';')[0];
  return {status:res.status,etag:res.headers.get('etag'),body:await res.json().catch(()=>null)};
}
try {
  for(let i=0;!output.includes(`localhost:${port}`);i++) {
    if(i>100 || server.exitCode!==null) throw new Error(output);
    await new Promise(r=>setTimeout(r,100));
  }
  assert.equal((await api('POST','/api/register',{username:'timestamps',password:'a-long-enough-password'})).status,200);
  const wire=c=>[c.id,c.first,c.last,c.hits,c.fixes,c.visitDates,c.visitTimes];
  assert.equal((await api('POST','/api/cells/import',{source:'phone',cells:cells.map(wire)})).status,200);
  let read=await api('GET','/api/cells');
  assert.deepEqual(read.body.rows.find(r=>r[0]===first.id)[8],first.visitTimes);
  const db=new DatabaseSync(dbPath);
  assert.deepEqual(JSON.parse(db.prepare('SELECT visit_times FROM cell_sources WHERE cell_id=?').get(first.id).visit_times),first.visitTimes,'timestamps are durable, not response-only');
  db.close();
  const extra=first.visitTimes[0]+30;
  await api('POST','/api/cells/import',{source:'phone',cells:[wire({...first,visitTimes:[extra]})]});
  const refreshed=await api('GET','/api/cells',undefined,{'If-None-Match':read.etag});
  assert.equal(refreshed.status,200,'an intermediate timestamp invalidates the cells cache');
  assert.equal((await api('POST','/api/cells/import',{source:'phone',cells:[[first.id,first.first,first.last,first.hits,first.fixes]]})).status,400,'obsolete import rows are rejected');
  assert.equal((await api('POST','/api/cells/restore',{rows:[[first.id,'phone',start,first.first,first.last,1,1]]})).status,400,'obsolete restore rows are rejected');
  assert.deepEqual((await api('GET','/api/cells')).body.rows.find(r=>r[0]===first.id)[8],normalizeVisitTimes([...first.visitTimes,extra]),'rejected writes leave measured history unchanged');
  const tripData=await api('GET','/api/trips');
  assert.equal(tripData.body.trips[0].points.length,13,'derived API threads every visit');
  const day=await api('GET',`/api/day/${dayKey(start)}`);
  assert.equal(day.body.points.length,13);
  await api('POST','/api/sources/rename',{from:'phone',to:'renamed'});
  const saved=(await api('GET','/api/cells')).body;
  const undo=await api('POST','/api/render/brush',{action:'erase',level:0,size:1,points:[[points[points.length-1].lng,47.4]]});
  assert.equal(undo.status,200,JSON.stringify(undo.body));
  assert.equal(undo.body.undo.rows[0].length,9,'native Undo includes times');
  await api('POST','/api/cells/restore',{rows:undo.body.undo.rows});
  assert.deepEqual((await api('GET','/api/cells')).body,saved,'native clear and undo preserve histories');
  await api('POST','/api/cells/mutate',{remove:cells.map(c=>c.id)});
  await api('POST','/api/cells/restore',{rows:saved.rows.map(([id,src,...rest])=>[id,saved.sources[src],...rest])});
  assert.deepEqual((await api('GET','/api/cells')).body,saved,'web clear and undo preserve histories');
  const device={id:'time-test-device',name:'Test',platform:'iOS'};
  await api('POST','/api/device/fixes',{device,fixes:points.slice(0,6).map(p=>[p.lat,p.lng,p.t])});
  await api('POST','/api/device/fixes',{device,fixes:points.slice(6).map(p=>[p.lat,p.lng,p.t])});
  await api('POST','/api/device/fixes',{device,fixes:points.map(p=>[p.lat,p.lng,p.t])});
  read=await api('GET','/api/cells');
  const deviceIndex=read.body.sources.indexOf('iphone');
  assert.notEqual(deviceIndex,-1);
  assert.equal(read.body.rows.filter(r=>r[1]===deviceIndex).reduce((n,r)=>n+r[8].length,0),12,'split and retried device uploads keep each timestamp once');
  console.log('Visit timestamps: aggregation, trip/day chronology, trace recovery, worker, migration, durable storage, cache, current-only contracts, rename, undo and device batches passed');
} finally {
  server.kill();
  await new Promise(resolve=>server.exitCode!==null?resolve():server.once('exit',resolve));
  await rm(dir,{recursive:true,force:true});
}
