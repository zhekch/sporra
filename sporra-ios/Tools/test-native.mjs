// Exercise the actual Swift networking code against an isolated, disposable server.
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
try {
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6',
    path.join(root, 'sporra-ios/Sporra/Native/ServerAPI.swift'),
    path.join(root, 'sporra-ios/Sporra/Native/NativeRail.swift'),
    path.join(root, 'sporra-ios/Tools/NativeAPICheck.swift'), '-o', path.join(temporary, 'native-check')]);
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
} finally {
  if (server && server.exitCode === null) { const done = new Promise(resolve => server.once('exit', resolve)); server.kill(); await done; }
  await rm(temporary, { recursive: true, force: true });
}
