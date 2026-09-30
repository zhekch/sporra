// Komoot's tour page says 1 h 49 min. The import used to say 163 hours.
//
// `duration` and the coordinate clock on that tour are the same absurd span,
// and every fix but the first shares the timestamp at the end of it.
// `time_in_motion` is the number on the page. A line that already has a pace
// keeps its own timestamps — flattening those would erase the pauses.
//
//   node scripts/test/komoot-clock.mjs

import { applyKomootClock } from '../../src/komoot.js';
import { buildRoutes, formatDuration, recordedSeconds } from '../../src/routes.js';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

const START = 1_720_000_000;

// ~111.3 km per degree of latitude. Dense enough that a spread clock does not
// look like a pause: the real tour's fixes are about 50 m apart.
function along(metres, n, tOf) {
  const step = metres / (n - 1) / 111_320;
  const points = [];
  for (let i = 0; i < n; i++) points.push({ lat: 46.9 + step * i, lng: 7.47, t: tOf(i, n) });
  return points;
}

const offsets = (points) => points.map((p) => p.t - START);

console.log('\na clock left open');
// The real tour: 11.8 km, duration 588118 s, time in motion 6586 s, one fix
// at the start and the rest piled 163 hours later.
{
  const points = along(11829, 200, (i) => (i === 0 ? 0 : 588118));
  const { durationSec, lastAt } = applyKomootClock(points, {
    motionSec: 6586, wallSec: 588118, lengthM: 11829, startedAt: START,
  });
  check(durationSec === 6586, 'the moving time is the duration', `${durationSec}`);
  check(formatDuration(durationSec) === '1 h 50 min', 'which is the 1 h 49 min on the page, rounded',
    formatDuration(durationSec));
  check(lastAt - START === 6586, 'and the route ends then, not 163 hours later');
  check(offsets(points)[0] === 0 && offsets(points).at(-1) === 6586, 'the fixes run from the start to that end');
  check(offsets(points).every((t, i, all) => i === 0 || t >= all[i - 1]), 'in order');
  const [route] = buildRoutes(
    [{ name: 'Ride', segments: [points], firstAt: START, lastAt, sport: 'Bike tour' }],
    { source: 'komoot' },
  );
  check(route && recordedSeconds(route) === 6586, 'and the card keeps it',
    route ? `${formatDuration(recordedSeconds(route))} over ${route.lengthM} m` : 'no route');
  check(route?.geom.length === 1, 'the line stays one piece');
}

console.log('\nunchanged when the coordinates already have a pace');
{
  const original = [0, 1000, 2400, 3600];
  const points = along(20000, 4, (i) => original[i]);
  const { durationSec, lastAt } = applyKomootClock(points, {
    motionSec: 3400, wallSec: 3700, lengthM: 20000, startedAt: START,
  });
  check(offsets(points).join() === original.join(), 'pauses in a real line stay where they were',
    offsets(points).join());
  check(durationSec === 3700 && lastAt - START === 3700, 'the wall clock is kept when it is believable');
}

console.log('\na wall clock that lies, on a line that does not');
{
  const original = [0, 1200, 3600];
  const points = along(20000, 3, (i) => original[i]);
  const { durationSec, lastAt } = applyKomootClock(points, {
    motionSec: 3400, wallSec: 588118, lengthM: 20000, startedAt: START,
  });
  check(offsets(points).join() === original.join(), 'the fixes are not moved');
  check(durationSec === 3600 && lastAt - START === 3600, 'and the absurd duration does not extend the ride',
    `${durationSec} ending +${lastAt - START}`);
}

console.log('\nno date');
{
  const points = along(11829, 20, (i) => (i === 0 ? 0 : 588118));
  const { durationSec, lastAt } = applyKomootClock(points, {
    motionSec: 6586, wallSec: 588118, lengthM: 11829, startedAt: 0,
  });
  check(durationSec === 6586 && lastAt === 0, 'the summary still learns the moving time');
  check(points.every((p) => p.t === 0), 'and an undated fix does not become 1970');
}

console.log(fail ? `\n${fail} failed` : `\n${pass} passed`);
process.exit(fail ? 1 : 0);
