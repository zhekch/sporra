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
  forget(); let reads=0; const supply=()=>{reads++;return input;}; const opts=cellsOptions(new URLSearchParams());
  cells(1,'a',supply,opts);cells(1,'a',supply,{...opts,bbox:[-1,-1,1,1]});check(reads===1,'viewport reuses rollup');
  cells(1,'b',supply,opts);check(reads===2,'signature rebuilds');
  const dateId='0/312741/0';
  const dateInput={cellIds:[dateId],cellMeta:new Map([[dateId,[{source:'manual'}]]])};
  const crossing={...opts,bbox:[170,-1,-170,1]};
  check(cells(2,'a',()=>dateInput,crossing).rows.length===1,'crossing viewport includes date-line cell');
  check(cells(3,'a',()=>({cellIds:[],cellMeta:new Map()}),opts).rows.length===0,'account caches are isolated');
  check(cells(1,'b',supply,{...opts,bbox:[40,40,41,41]}).rows.length===0,'empty viewport');

} catch(e) { check(false,'test run',e.stack); }
finally { server.kill();await rm(dir,{recursive:true,force:true}); }
console.log(`render API: ${pass} ok, ${fail} failed`);process.exit(fail?1:0);
