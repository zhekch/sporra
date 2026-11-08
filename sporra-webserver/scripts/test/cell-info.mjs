import assert from 'node:assert/strict';
import { mountCellInfo } from '../../src/cell-info.js';

class Element {
  children = []; hidden = false; attributes = {}; events = {};
  set textContent(value) { this.text = value; this.children = []; }
  get textContent() { return (this.text ?? '') + this.children.map(c => c.textContent).join(''); }
  replaceChildren(...children) { this.text = ''; this.children = children; }
  append(...children) { this.children.push(...children); }
  setAttribute(name, value) { this.attributes[name] = value; }
  addEventListener(name, fn) { this.events[name] = fn; }
  click() { this.events.click?.(); }
}
const ids = Object.fromEntries(['cell-info','cell-info-title','cell-info-close','cell-info-coord','cell-info-rows','cell-info-dates'].map(id => [id,new Element()]));
globalThis.document = {getElementById:id=>ids[id], createElement:()=>new Element()};
const dates = ['2024-04-05','2024-02-03','2024-01-01'];
let resolve;
const view = mountCellInfo({loadDates: () => new Promise(r => resolve = r)});
view.show({title:'Bern',visited:true,visitDates:dates,visitCount:3});
assert.equal(ids['cell-info-coord'].textContent, '3 visits');
assert.equal(ids['cell-info-dates'].hidden, true);
const toggle = ids['cell-info-coord'].children[0];
toggle.click();
assert.equal(ids['cell-info-coord'].children[0], toggle, 'rotation keeps the same DOM node so CSS can animate');
assert.equal(ids['cell-info-dates'].hidden, false);
assert.equal(ids['cell-info-coord'].children[0].attributes['aria-expanded'], 'true');
assert.deepEqual(ids['cell-info-dates'].children[0].children.map(li => li.children[0].dateTime), dates);
ids['cell-info-coord'].children[0].click();
assert.equal(ids['cell-info-dates'].hidden, true);
await Promise.resolve();
view.hide();
resolve({name:'Stale place',visitDates:dates,visitCount:3});
await new Promise(r=>setTimeout(r,0));
assert.equal(ids['cell-info'].hidden,true);
assert.equal(ids['cell-info-title'].textContent,'Bern');
view.show({visited:true,visitDates:[]});
assert.equal(ids['cell-info-title'].children[0].className, 'place-name-dots');
assert.equal(ids['cell-info-title'].children[0].children.length, 3);
assert.equal(ids['cell-info-title'].textContent, '');
await Promise.resolve();
resolve({name:'Bern',visited:true,visitDates:dates,visitCount:3});
await new Promise(r=>setTimeout(r,0));
assert.equal(ids['cell-info-title'].textContent, 'Bern');
assert.equal(ids['cell-info-title'].children[0].className, 'place-name-ready');
const offline = mountCellInfo({loadDates:async()=>{throw new Error('offline');}});
offline.show({title:'Bern',visited:false,visitDates:[]});
await new Promise(r=>setTimeout(r,0));
assert.equal(ids['cell-info-coord'].textContent,'Not visited yet');
assert.equal(ids['cell-info-dates'].hidden,true);
offline.show({title:'Bern',visited:true,visitDates:[]});
assert.equal(ids['cell-info-coord'].textContent,'You have been here');
console.log('cell info: date disclosure, accessible toggle, stale response and offline checks passed');
