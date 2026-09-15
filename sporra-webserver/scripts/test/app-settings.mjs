// The door from Personal into the iOS app's own settings.
//
//   node scripts/test/app-settings.mjs
//
// This layer has the same failure mode as the photo overlay: **its other half
// is in another language.** The page asks `sporraSettings` for `open`; a Swift
// file two directories away switches on that exact string, and neither compiler
// nor bundler has ever seen both. Rename one and the row still appears, still
// looks like a door, and the tap answers "unknown".
//
// The rest is the handful of things that are wrong in a way you cannot see: a
// row that is not hidden by default shows up in a browser as a control that
// cannot work, and a handler that is never registered is a row that stays
// hidden in the one place it is for.

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const REPO = path.resolve(ROOT, '..');
const read = (rel) => readFileSync(path.join(ROOT, rel), 'utf8');
const readApp = (rel) => readFileSync(path.join(REPO, rel), 'utf8');

const js = read('src/personal-ui.js');
const html = read('index.html');
const css = read('src/style.css');
const bridge = readApp('sporra-ios/Sporra/SettingsBridge.swift');
const webPanel = readApp('sporra-ios/Sporra/WebPanel.swift');
const content = readApp('sporra-ios/Sporra/ContentView.swift');
const settings = readApp('sporra-ios/Sporra/SettingsView.swift');

console.log('\nThe page and the app agree about what to call each other');
{
  const jsName = js.match(/const APP_SETTINGS = '([^']+)'/)?.[1];
  const swiftName = bridge.match(/static let name = "([^"]+)"/)?.[1];
  check(!!jsName && jsName === swiftName, 'the message handler has one name', `${jsName} vs ${swiftName}`);
  check(
    webPanel.includes('addScriptMessageHandler(') && webPanel.includes('SettingsBridge.name'),
    'and the web view actually registers it',
  );

  const asked = [...js.matchAll(/ask: '([a-z]+)'/g)].map((m) => m[1]);
  const answered = [...bridge.matchAll(/case "([a-z]+)":/g)].map((m) => m[1]);
  const unanswered = asked.filter((a) => !answered.includes(a));
  check(asked.includes('open'), 'the page asks to open the screen');
  check(!unanswered.length, 'and the app answers every question', unanswered.join(', '));
  const unasked = answered.filter((a) => !asked.includes(a));
  check(!unasked.length, 'with nothing left over that nobody asks', unasked.join(', '));
}

console.log('\nThe row is a door, not a control that cannot work');
{
  check(html.includes('id="settings-app"'), 'Personal has the row');
  check(
    /id="settings-app"[^>]*\shidden|hidden[^>]*\sid="settings-app"/.test(html),
    'and it is hidden until the host answers',
  );
  check(js.includes('appBtn.hidden = !appSettingsHost()'), 'draw() shows it only when the handler is there');
  check(js.includes("appSettingsHost()"), 'the page looks for the handler, not for data-client');
  check(!html.includes('settings-app') || /pane-personal[\s\S]*id="settings-app"/.test(html),
    'it sits in Personal');
  const personal = html.slice(html.indexOf('id="pane-personal"'), html.indexOf('id="pane-maplayers"'));
  const appAt = personal.indexOf('id="settings-app"');
  const homeAt = personal.indexOf('id="settings-home-name"');
  check(appAt >= 0 && homeAt >= 0 && appAt < homeAt, 'and at the top of it, above Home');
}

console.log('\nThe screen it opens is the existing one');
{
  check(content.includes('SettingsView()'), 'ContentView presents SettingsView');
  check(content.includes('SettingsBridge.shared'), 'from the same bridge the page talks to');
  check(content.includes('.sheet(isPresented'), 'as a sheet over the map');
  check(settings.includes('Button("Done")'), 'and the sheet can be put away');
  check(content.includes('SetupPage'), 'before there is a server, a setup page offers the same door');
  check(content.includes('Open settings'), 'with a button that says so');
  check(!content.includes('TabView'), 'and there is no tab bar under the map');
}

console.log('\nIt is styled, and only in the app');
{
  check(css.includes('.app-settings-row'), 'the row has a style');
  check(css.includes('.app-settings-row[hidden]'), 'and hidden really hides it');
}

console.log(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
