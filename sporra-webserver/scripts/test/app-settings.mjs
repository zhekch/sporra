// The current iOS app opens native settings without an embedded web host.
import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const REPO = path.resolve(ROOT, '..');
const readApp = rel => readFileSync(path.join(REPO, rel), 'utf8');
const content = readApp('sporra-ios/Sporra/ContentView.swift');
let pass = 0, fail = 0;
const check = (ok, label) => { console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}`); ok ? pass++ : fail++; };
console.log('\nThe iOS app opens settings through native screens');
{
  const menu = readApp('sporra-ios/Sporra/Native/NativeMenu.swift');
  const nativeSettings = readApp('sporra-ios/Sporra/Native/NativeSettings.swift');
  check(content.includes('NativeMap(store:'), 'the map is a native SDK view');
  check(!content.includes('WebPanel('), 'the native interface does not host the web app');
  check(menu.includes('NativeSettings(store:'), 'the native menu opens native settings');
  check(content.includes('.sheet(isPresented'), 'menus use system sheets over the map');
  check(content.includes('Button("Done")'), 'the sheet can be put away');
  check(content.includes('NativeLogin(store:'), 'before signing in, native setup connects to the server');
  check(nativeSettings.includes('NativeDeviceSettings(store:'), 'native settings retain phone recording controls');
  check(!content.includes('TabView'), 'there is no tab bar under the map');
}


check(!existsSync(path.join(REPO, 'sporra-ios/Sporra/WebPanel.swift')), 'the obsolete iOS web host has been removed');
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
