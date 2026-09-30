// A car line from OSRM and a train line from Transitous, as coordinates the
// edit panel can colour in.
//
//   node scripts/test/directions.mjs

import {
  carRequestUrl,
  decodePolyline,
  lineFromOsrm,
  lineFromTransitous,
  placeOk,
  placesApart,
  trainRequestUrl,
} from '../../src/directions.js';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

const near = (p, lng, lat) => Math.abs(p[0] - lng) < 1e-4 && Math.abs(p[1] - lat) < 1e-4;

// The example from Google's polyline algorithm documentation.
const sample = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@', 5);
check(sample.length === 3, 'decodes the three-point sample', String(sample.length));
check(near(sample[0], -120.2, 38.5), 'first point is the documented one', JSON.stringify(sample[0]));
check(near(sample[1], -120.95, 40.7), 'second point is the documented one', JSON.stringify(sample[1]));
check(near(sample[2], -126.453, 43.252), 'third point is the documented one', JSON.stringify(sample[2]));
check(decodePolyline('', 5).length === 0, 'an empty string is no line');
check(decodePolyline(null, 5).length === 0, 'a missing string is no line');

const thun = { lng: 7.621, lat: 46.758 };
const bern = { lng: 7.439, lat: 46.949 };
check(placesApart(thun, bern), 'Thun and Bern are a trip');
check(!placesApart(thun, { lng: 7.62105, lat: 46.75805 }), 'two taps on one junction are not');
check(!placeOk({ lng: 200, lat: 46 }), 'a longitude past the world is refused');
check(placeOk(thun), 'Thun is a place');

const carUrl = new URL(carRequestUrl(thun, bern));
check(carUrl.origin + carUrl.pathname === 'https://routing.openstreetmap.de/routed-car/route/v1/driving/7.621,46.758;7.439,46.949', 'car asks FOSSGIS, longitude first');
check(carUrl.searchParams.get('overview') === 'full', 'car asks for the unsimplified road');
check(carUrl.searchParams.get('geometries') === 'geojson', 'car asks for coordinates, not an encoded string');

const trainUrl = new URL(trainRequestUrl(thun, bern));
check(trainUrl.origin + trainUrl.pathname === 'https://api.transitous.org/api/v6/plan', 'train asks Transitous');
check(trainUrl.searchParams.get('fromPlace') === '46.758,7.621', 'train sends latitude first');
check(trainUrl.searchParams.get('transitModes') === 'RAIL,SUBURBAN', 'train asks for rail');
check(trainUrl.searchParams.get('directModes') === '', 'train does not ask for a direct walk');
check(trainUrl.searchParams.get('preTransitModes') === 'WALK', 'the walk to the station stays');
check(trainUrl.searchParams.get('detailedLegs') === 'true', 'train asks for the leg geometry');

const osrm = lineFromOsrm({
  code: 'Ok',
  routes: [{ geometry: { type: 'LineString', coordinates: [[7.62, 46.76], [7.5, 46.8], [7.44, 46.95]] } }],
});
check(osrm?.length === 3 && near(osrm[2], 7.44, 46.95), 'OSRM GeoJSON becomes the line');
check(lineFromOsrm({ code: 'NoRoute', routes: [] }) === null, 'no road is no line');
const encoded = lineFromOsrm({ code: 'Ok', routes: [{ geometry: '_p~iF~ps|U_ulLnnqC_mqNvxq`@' }] });
check(encoded?.length === 3 && near(encoded[0], -120.2, 38.5), 'an encoded OSRM line still decodes');

// Precision 5 of a two-point leg, then a second leg that starts where it ended.
const transit = lineFromTransitous({
  itineraries: [{
    legs: [
      {
        from: { lat: 46.76, lon: 7.62 },
        to: { lat: 46.8, lon: 7.5 },
        legGeometry: { points: '_p~iF~ps|U_ulLnnqC_mqNvxq`@', precision: 5, length: 3 },
      },
      {
        from: { lat: 43.252, lon: -126.453 },
        to: { lat: 43.3, lon: -126.4 },
        legGeometry: { points: '', precision: 6, length: 0 },
      },
    ],
  }],
});
check(transit?.length === 4, 'a shaped leg plus a stop-to-stop leg is one line', String(transit?.length));
check(transit && near(transit[0], -120.2, 38.5), 'the shaped leg is the start of the line');
check(transit && near(transit[2], -126.453, 43.252), 'the shared join is not repeated', JSON.stringify(transit?.[2]));
check(transit && near(transit[3], -126.4, 43.3), 'a leg with no shape still joins its stops');
check(lineFromTransitous({ itineraries: [] }) === null, 'no itinerary is no line');
check(lineFromTransitous({}) === null, 'an empty answer is no line');

const coach = lineFromTransitous({
  itineraries: [{
    legs: [
      {
        mode: 'WALK',
        from: { lat: 50.107, lon: 8.663 },
        to: { lat: 50.107, lon: 8.662 },
        legGeometry: { points: '', precision: 6, length: 0 },
      },
      {
        mode: 'COACH',
        from: { lat: 50.107, lon: 8.662 },
        to: { lat: 51.443, lon: 5.48 },
        legGeometry: { points: '_p~iF~ps|U_ulLnnqC_mqNvxq`@', precision: 5, length: 3 },
      },
    ],
  }],
});
check(coach === null, 'a coach is not drawn as the train');

const rail = lineFromTransitous({
  itineraries: [{
    legs: [
      {
        mode: 'WALK',
        from: { lat: 50.11, lon: 8.66 },
        to: { lat: 50.107, lon: 8.663 },
        legGeometry: { points: '', precision: 6, length: 0 },
      },
      {
        mode: 'NIGHT_RAIL',
        from: { lat: 50.107, lon: 8.663 },
        to: { lat: 52.089, lon: 5.11 },
        legGeometry: { points: '', precision: 6, length: 0 },
      },
      {
        mode: 'REGIONAL_RAIL',
        from: { lat: 52.089, lon: 5.11 },
        to: { lat: 51.443, lon: 5.481 },
        legGeometry: { points: '', precision: 6, length: 0 },
      },
    ],
  }],
});
check(rail?.length === 4 && near(rail[0], 8.66, 50.11) && near(rail[3], 5.481, 51.443), 'a night train and a regional train are one line');
check(lineFromTransitous({
  itineraries: [{ legs: [{ mode: 'WALK', from: { lat: 50, lon: 8 }, to: { lat: 50.01, lon: 8.01 }, legGeometry: { points: '', precision: 6 } }] }],
}) === null, 'a walk with no train is no line');

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
