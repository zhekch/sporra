import assert from 'node:assert/strict';
let stored = {};
globalThis.localStorage = {
  getItem: key => stored[key] ?? null,
  setItem: (key, value) => { stored[key] = String(value); },
  removeItem: key => { delete stored[key]; },
};
await (await import('../../src/i18n.js')).loadLocale('en');
const {bannerMode, setBannerMode, isBannerMode, lastSnapshot, rememberSnapshot, mergeSnapshots, forgetSnapshot} = await import('../../src/whats-new.js');
assert.equal(bannerMode(), 'substantial');
for (const mode of ['never','substantial','always']) {
  assert.equal(isBannerMode(mode), true);
  setBannerMode(mode);
  assert.equal(bannerMode(), mode);
}
assert.equal(setBannerMode('invalid'), 'substantial');
assert.equal(isBannerMode('invalid'), false);
assert.equal(lastSnapshot(), null);
rememberSnapshot({cells:10,countries:1,workouts:2});
assert.equal(lastSnapshot().cells, 10);
assert.equal(lastSnapshot().workouts, 2);
const merged = mergeSnapshots(lastSnapshot(), {cells:5,countries:2,workouts:3});
assert.equal(merged.cells, 10);
assert.equal(merged.countries, 2);
assert.equal(merged.workouts, 3);
forgetSnapshot();
assert.equal(lastSnapshot(), null);
console.log('Announcement frequency and legacy preference compatibility passed.');
