import assert from 'node:assert/strict';
import { installTownLabelClicks, townLabel } from '../../src/town-labels.js';
import { townAt, visitDatesForArea, prime } from '../../server/render-geography.js';
import { resolveTown, nearestTown } from '../../src/places.js';
import { pointToCell, normCol, colsOf, mercX, mercY } from '../../src/hexgrid.js';

const feature = {properties: {class: 'settlement', name: 'Zurich'}, geometry: {type: 'Point', coordinates: [8.55, 47.367]}};
const interactions = new Map(), clicks = [];
const map = {addInteraction: (id, interaction) => interactions.set(id, interaction)};
installTownLabelClicks(map, (event, town) => clicks.push({event, town}));
const labelClick = interactions.get('sporra-town-click');
assert.deepEqual(labelClick.target, {featuresetId:'place-labels', importId:'basemap'});
assert.equal(labelClick.handler({feature, lngLat:{lng:8.6,lat:47.4}}), true);
assert.deepEqual(clicks[0].town, {name:'Zurich',lng:8.55,lat:47.367}, 'use the town geometry, not the point under the text');
assert.equal(labelClick.handler({feature:{...feature, properties:{name:'Switzerland',class:'country'}}}), false);
assert.equal(clicks.length,1,'country labels leave the town selection alone');
interactions.get('sporra-map-click').handler({lngLat:{lng:8.6,lat:47.4}});
assert.equal(clicks.length,2);
assert.equal(clicks[1].town,undefined,'background taps retain ordinary cell handling');
assert.equal(townLabel({...feature,geometry:{type:'Point',coordinates:[NaN,47]}}),null);
let libreClick;
installTownLabelClicks({on:(type,fn)=>{assert.equal(type,'click');libreClick=fn;}}, () => {});
assert.equal(typeof libreClick,'function','MapLibre keeps its existing gesture path');

await prime();
assert.equal(resolveTown(-9.15,38.725,'Lisbon')?.lng,-9.15,'same-name towns use coordinates');
assert.equal(resolveTown(-30,40,'Lisbon'),null,'distant labels cannot borrow the nearest familiar name');
assert.equal(nearestTown(8.489,47.391)?.name,'Zürich','districts remain grouped with their city');
const idAt = (lng,lat) => { const [c,r]=pointToCell(0,mercX(lng),mercY(lat)); return `0/${normCol(c,colsOf(0))}/${r}`; };
const id=idAt(8.54,47.37), other=idAt(8.725,47.5);
const metadata = (day,source='iphone') => ({source,visitDates:[day]});
const input={cellIds:[id,other],cellMeta:new Map([[id,[metadata('2024-01-01')]],[other,[metadata('2024-02-01')]]])};
const supplyRoutes=()=>[{
  source:'iphone',geom:[[[8.54,47.37],[8.725,47.5],[8.53,47.38]]],
  trace:[[[0,Date.parse('2024-01-03')/1000],[0,Date.parse('2024-02-03')/1000],[0,Date.parse('2024-01-09')/1000]]],
}];
const town=await townAt(input,8.55,47.367,'Zurich',[],supplyRoutes);
assert.deepEqual(town.visitDates,['2024-01-03','2024-01-01'],'recover only measured dates from retained town cells');
assert.deepEqual((await visitDatesForArea(input,'town',town.area.id,[],supplyRoutes)).visitDates,town.visitDates);
assert.deepEqual((await townAt(input,8.55,47.367,'Zurich',['iphone'],supplyRoutes)).visitDates,[]);
console.log('Town label callbacks and shared town aggregation passed');
