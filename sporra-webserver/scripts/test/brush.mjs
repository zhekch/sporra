// The edit brush is a disk of hexes. A disk that is the wrong cells is a brush
// that paints the neighbour of the one you are pointing at, which is the sort
// of thing that looks like the cursor being a pixel off and is not.
//
// Two checks that do not share a formula with cellsWithin: how many cells a
// hex disk of radius n contains (3n(n+1)+1, which is just the rings summed),
// and that each returned cell's own centre falls inside the circle of n steps.
// The round-trip through pointToCell is the third — a coordinate the lattice
// itself does not recognise is not a cell, whatever the count says.
//
//   node scripts/test/brush.mjs

import {
  BRUSH_STEPS, brushRadius, cellCenter, cellsOnPolyline, cellsWithin, colsOf,
  holdPointerSample, normCol, pointToCell,
  radiusOf, sampleOnSegment, segmentSamples, SQRT3,
} from '../../src/hexgrid.js';

let pass = 0;
let fail = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);
  ok ? pass++ : fail++;
};

const diskCount = (n) => 3 * n * (n + 1) + 1;
// Centre-to-centre is the flat-to-flat distance, √3·R. A step of the disk is
// one of those, so the far cells of a radius-n disk sit n steps out and the
// next ring would sit one further.
const step = (L) => SQRT3 * radiusOf(L);

console.log('\nA brush is a disk of the cells it claims');
{
  for (const reach of [0, 1, 2, 5]) {
    const cells = cellsWithin(100, 40, reach);
    check(cells.length === diskCount(reach),
      `reach ${reach} has ${diskCount(reach)} cells`, String(cells.length));
    const seen = new Set(cells.map(([c, r]) => `${c}/${r}`));
    check(seen.size === cells.length, `reach ${reach} has no duplicate`);
  }

  // Both parities, because the odd column is the one shifted half a row and
  // the conversion is the part that would be off by that half.
  for (const col of [100, 101, -1, 0]) {
    for (const reach of [0, 1, 3]) {
      const row = 40;
      const cells = cellsWithin(col, row, reach);
      const [cx, cy] = cellCenter(0, col, row);
      let far = 0;
      let roundTrip = true;
      let inCircle = true;
      for (const [c, r] of cells) {
        const [x, y] = cellCenter(0, c, r);
        const [c2, r2] = pointToCell(0, x, y);
        if (c2 !== c || r2 !== r) roundTrip = false;
        const d = Math.hypot(x - cx, y - cy);
        if (d > far) far = d;
        if (d > reach * step(0) + 1e-6) inCircle = false;
      }
      check(roundTrip, `centres around (${col}, ${row}) reach ${reach} are those cells`);
      check(inCircle, `and they sit within ${reach} steps of it`);
      const want = reach * step(0);
      check(reach === 0 ? far === 0 : Math.abs(far - want) < 1e-6,
        `the furthest is exactly ${reach} steps out`, far.toFixed(3));
    }
  }

  // Column −1 is the cell just west of the prime meridian. Wrapped, that is
  // column N−1, which is the same hex — and a world away if you draw it
  // unwrapped the other way. The disk must keep the continuous one.
  const west = cellsWithin(0, 10, 1);
  check(west.some(([c]) => c === -1), 'the western neighbour of column 0 is column −1');
  const N = colsOf(0);
  const ids = new Set(west.map(([c, r]) => `${normCol(c, N)}/${r}`));
  check(ids.size === west.length && ids.has(`${N - 1}/10`),
    'and that neighbour\'s id is the wrapped column, once');
  const xs = west.map(([c, r]) => cellCenter(0, c, r)[0]);
  check(Math.max(...xs) - Math.min(...xs) < step(0) * 3,
    'the disk stays on one side of the world');
}

console.log('\nA stroke fills the cells between two samples');
{
  const end = segmentSamples(0, 0, 10, 0, 100);
  check(end.length === 1 && end[0][0] === 10 && end[0][1] === 0,
    'shorter than a step is just the end');

  const line = segmentSamples(0, 0, 100, 0, 30);
  check(line.length === 4, 'three gaps and the end', String(line.length));
  check(line[line.length - 1][0] === 100 && line[line.length - 1][1] === 0, 'it lands on the end');
  check(line[0][0] !== 0, 'and does not repeat the start');
  let spaced = true;
  let prev = 0;
  for (const [x] of line) {
    if (x - prev > 30 + 1e-9) spaced = false;
    prev = x;
  }
  check(spaced, 'no gap larger than the step');

  const diag = segmentSamples(0, 0, 30, 40, 1000);
  check(diag.length === 1 && diag[0][0] === 30 && diag[0][1] === 40,
    'a diagonal shorter than a step is the end');

  const leap = segmentSamples(0, 0, 5000, 0, 10, 1000);
  check(leap.length === 1 && leap[0][0] === 5000,
    'a leap past maxDist is not filled in', String(leap.length));

  const along = segmentSamples(0, 0, 0, 90, 40);
  check(along.every(([, y], i) => Math.abs(y - (i + 1) * 30) < 1e-9),
    'the samples sit on the segment');
}

console.log('\nA coalesced sample counts only when it is on the way');
{
  check(sampleOnSegment(500, 200, 560, 200, 530, 204),
    'a sample on the way to the dispatched point is part of the stroke');
  check(!sampleOnSegment(500, 200, 560, 200, 230, 200),
    'a sample off that segment is not');
  check(!sampleOnSegment(500, 200, 560, 200, 400, 200),
    'and neither is one back toward where the pointer is not');
}

// A twitch and a flick are the same number in one sample. What tells them
// apart is the sample after: the pointer is still out there, or it never left.
console.log('\nA sample that leaps waits for the one after it');
{
  const LIMIT = 120;
  const hold = (from, held, to) => holdPointerSample(from, held, to, LIMIT);
  check(!hold([500, 200], null, [540, 214]), 'an ordinary step is believed at once');
  check(!hold(null, null, [200, 200]), 'and so is the first sample of all, having nothing to leap from');
  check(hold([500, 200], null, [180, 206]), 'a step across the map is held back');
  check(!hold([500, 200], [180, 206], [150, 230]),
    'the sample after it, still out there, is the pointer having moved');
  check(!hold([500, 200], [180, 206], [505, 204]),
    'one back under the cursor is believed where it lands, and the leap it answers goes unused');
  check(hold([500, 200], [180, 206], [900, 210]),
    'a second leap somewhere else is held in its turn');
}

console.log('\nThe brush steps widen');
{
  check(BRUSH_STEPS[0] === 1 && BRUSH_STEPS[1] === 3 && BRUSH_STEPS[2] === 8 && BRUSH_STEPS[3] === 15,
    'the first steps are 1, 3, 8, 15');
  let widening = true;
  for (let i = 2; i < BRUSH_STEPS.length; i++) {
    const gap = BRUSH_STEPS[i] - BRUSH_STEPS[i - 1];
    const prev = BRUSH_STEPS[i - 1] - BRUSH_STEPS[i - 2];
    if (!(gap > prev)) widening = false;
  }
  check(widening, 'each gap is wider than the one before it');
  check(brushRadius(1) === 1 && brushRadius(8) === 8, 'a step that is still a step stays put');
  check(brushRadius(2) === 3 && brushRadius(6) === 8, 'an old in-between size snaps to the ladder',
    `${brushRadius(2)}, ${brushRadius(6)}`);
  check(brushRadius(99) === 99, 'the widest step is a step');
}

console.log('\nA line of track names every cell it crosses');
{
  const axial = (col, row) => {
    const q = col;
    const r = row - (q - (q & 1)) / 2;
    return [q, r, -q - r];
  };
  const hexDist = (a, b) => {
    const [q1, r1, s1] = axial(a[0], a[1]);
    const [q2, r2, s2] = axial(b[0], b[1]);
    return Math.max(Math.abs(q1 - q2), Math.abs(r1 - r2), Math.abs(s1 - s2));
  };
  const [x, y] = cellCenter(0, 100, 40);
  const one = cellsOnPolyline(0, [[x, y]]);
  check(one.length === 1 && one[0][0] === 100 && one[0][1] === 40, 'a point is its own cell');
  const [x2, y2] = cellCenter(0, 101, 40);
  const step = cellsOnPolyline(0, [[x, y], [x2, y2]]);
  const keys = new Set(step.map(([c, r]) => `${c}/${r}`));
  check(keys.has('100/40') && keys.has('101/40'), 'the neighbour at the far end is included');
  const [x3, y3] = cellCenter(0, 130, 40);
  const line = cellsOnPolyline(0, [[x, y], [x3, y3]]);
  const seen = new Set(['0']);
  const queue = [0];
  while (queue.length) {
    const i = queue.pop();
    for (let j = 0; j < line.length; j++) {
      if (seen.has(String(j)) || hexDist(line[i], line[j]) !== 1) continue;
      seen.add(String(j));
      queue.push(j);
    }
  }
  check(line.length > 10 && seen.size === line.length, 'thirty columns of line is one connected ribbon',
    `${seen.size}/${line.length}`);
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
