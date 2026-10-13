import assert from 'node:assert/strict';
const elements = new Map();
for (const id of ['whats-new-bar','whats-new-title','whats-new-detail','whats-new-open','whats-new-dismiss']) {
  elements.set(id, {hidden:true,textContent:'',handlers:{},addEventListener(type,fn){this.handlers[type]=fn;}});
}
globalThis.document = {hidden:false,getElementById:id=>elements.get(id),addEventListener(){}};
globalThis.setInterval = () => 1;
globalThis.setTimeout = () => 2;
globalThis.clearTimeout = () => {};
const {mountWhatsNew} = await import('../../src/whats-new-ui.js');
let opened, loading = 0, load;
const ui = mountWhatsNew({
  load: quiet => {loading++; return load(quiet);},
  onOpenStats: (count, ids) => {opened={count,ids};},
});
load = async () => ({show:true,title:'New activity: Evening walk',detail:'First visit to Basel.',activities:1,activityIds:[99]});
await ui.show();
assert.equal(elements.get('whats-new-title').textContent, 'New activity: Evening walk');
assert.equal(elements.get('whats-new-detail').textContent, 'First visit to Basel.');
assert.equal(elements.get('whats-new-bar').hidden,false);
elements.get('whats-new-open').handlers.click();
assert.deepEqual(opened,{count:1,ids:[99]});
assert.equal(elements.get('whats-new-bar').hidden,true);
let sentQuiet;
load = async quiet => {sentQuiet=quiet;return {show:true};};
await ui.show({quiet:true});
assert.equal(sentQuiet,true);
assert.equal(elements.get('whats-new-bar').hidden,true);
let resolve;
load = () => new Promise(done=>{resolve=done;});
const pending=ui.show();
const calls=loading;
await ui.show();
assert.equal(loading,calls);
ui.hide();
resolve({show:true,title:'Old account news',detail:'',activities:0});
await pending;
assert.equal(elements.get('whats-new-bar').hidden,true);
load = async () => {throw new Error('offline');};
await ui.show();
assert.equal(elements.get('whats-new-bar').hidden,true);
console.log('Server announcement UI: text, exact IDs, quiet checks, concurrent requests and logout passed.');
