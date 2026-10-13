import { announcementFor, announcementBaseline } from '../../server/announcements.js';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const PORT = 3219;
const BASE = `http://127.0.0.1:${PORT}`;

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

const dir = await mkdtemp(path.join(tmpdir(), 'visited-map-announcements-'));
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

const empty = {countries:[],regions:[],cities:[],activities:[],km2:0};
const baseline = announcementBaseline(null, {...empty, activities:[{id:10,ids:['10'],name:'Ride'}]});
check(!announcementFor(baseline, {...empty, activities:[{id:12,ids:['12','10'],name:'Ride'}]}).show, 'a preferred duplicate recording is not a new workout');
check(announcementBaseline(baseline, empty).activityIds.includes('10'), 'deletions cannot roll back announced identities');

try {
  if (!(await waitForServer())) throw new Error(serverErr);
  check((await api('POST', '/api/whats-new', {})).status === 401, 'news requires authentication');
  await api('POST', '/api/register', {username:'news-test',password:'a-long-enough-pw'});
  check((await api('POST', '/api/whats-new', {})).body.show === false, 'first visit establishes a quiet baseline');
  const {pointToCell,mercX,mercY,colsOf,normCol} = await import('../../src/hexgrid.js');
  const cell = (lng,lat) => {
    const [c,r] = pointToCell(0,mercX(lng),mercY(lat));
    return `0/${normCol(c,colsOf(0))}/${r}`;
  };
  const visit = async (lng,lat) => api('POST','/api/cells/mutate',{add:[cell(lng,lat)]});
  await visit(7.4474,46.948);
  const bern = (await api('POST', '/api/whats-new', {})).body;
  check(bern.show && bern.detail.includes('Bern') && bern.detail.includes('Switzerland'), 'new city and country are named', JSON.stringify(bern));
  check((await api('POST', '/api/whats-new', {})).body.show === false, 'another client does not repeat the announcement');
  await visit(7.4478,46.9485);
  check((await api('POST', '/api/whats-new', {})).body.show === false, 'small additions in the same place stay quiet');
  const oldRows = (await api('GET','/api/cells')).body.rows;
  await api('POST','/api/cells/mutate',{remove:[...new Set(oldRows.map(row => row[0]))]});
  await visit(2.3522,48.8566);
  const parallel = await Promise.all([api('POST','/api/whats-new',{}),api('POST','/api/whats-new',{})]);
  check(parallel.filter(answer => answer.body.show).length === 1, 'simultaneous devices consume news only once');
  const paris = parallel.find(answer => answer.body.show).body;
  check(paris.detail.includes('Paris') && paris.detail.includes('France'), 'country and city identities survive equal counts', JSON.stringify(paris));
  await api('POST','/api/prefs',{prefs:{whatsNew:'never'}});
  await visit(12.4964,41.9028);
  check(!(await api('POST','/api/whats-new',{})).body.show, 'Never disables named-ground announcements');
  const gpx = '<?xml version="1.0"?><gpx><trk><name>New walk</name><trkseg><trkpt lat="47.37" lon="8.54"><time>2026-10-13T09:00:00Z</time></trkpt><trkpt lat="47.371" lon="8.542"><time>2026-10-13T09:01:00Z</time></trkpt><trkpt lat="47.372" lon="8.544"><time>2026-10-13T09:02:00Z</time></trkpt></trkseg></trk></gpx>';
  await api('POST','/api/import/file',{name:'walk.gpx',text:gpx,source:'gpx'});
  check(!(await api('POST','/api/whats-new',{})).body.show, 'Never also disables activity announcements');
  await api('POST','/api/prefs',{prefs:{whatsNew:'substantial'}});
  check(!(await api('POST','/api/whats-new',{})).body.show, 'enabling does not repeat news consumed while disabled');
  const nextGpx = gpx.replaceAll('09:', '10:').replace('New walk','Lunch walk').replaceAll('47.37','47.38');
  await api('POST','/api/import/file',{name:'lunch.gpx',text:nextGpx,source:'gpx'});
  const activity = (await api('POST','/api/whats-new',{})).body;
  check(activity.show && activity.activities === 1 && activity.activityIds.length === 1 && activity.title.includes('Lunch walk'), 'new activity from a non-Health source is announced by name', JSON.stringify(activity));
  await api('POST','/api/import/file',{name:'lunch.gpx',text:nextGpx,source:'gpx'});
  check(!(await api('POST','/api/whats-new',{})).body.show, 'reimport does not announce the same activity');
  await visit(-0.1276,51.5072);
  check(!(await api('POST','/api/whats-new',{quiet:true})).body.show, 'quiet check advances without showing a toast');
  check(!(await api('POST','/api/whats-new',{})).body.show, 'quiet history stays consumed');
  const originalCookie = cookie;
  await api('POST','/api/register',{username:'other-news',password:'a-long-enough-pw'});
  check(!(await api('POST','/api/whats-new',{})).body.show, 'another account has its own baseline');
  cookie = originalCookie;
  check(!(await api('POST','/api/whats-new',{})).body.show, 'other account does not erase this account baseline');
} catch(e) { check(false,'test run',e.stack); }
finally { server.kill();await rm(dir,{recursive:true,force:true}); }
console.log(`announcements API: ${pass} ok, ${fail} failed`);process.exit(fail?1:0);
