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
  acceptPointerSample, cellCenter, cellsWithin, colsOf, normCol, pointToCell, radiusOf,
  sampleOnSegment, segmentSamples, SQRT3,
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

console.log('\nA leap the device did not make is not where the pointer is');
{
  check(acceptPointerSample(500, 200, 508, 202, 0, 0),
    'a short step is kept even when the device reports none');
  check(!acceptPointerSample(500, 200, 220, 190, 0, 0),
    'a long leap with no device movement is dropped');
  check(!acceptPointerSample(500, 200, 224, 188, 2, -1),
    'and a second copy of that leap is still dropped');
  check(acceptPointerSample(500, 200, 200, 200, -300, 0),
    'a leap the device actually made is kept');
  check(acceptPointerSample(500, 200, 800, 200, undefined, undefined),
    'no movement reading has nothing to disagree with');

  check(sampleOnSegment(500, 200, 560, 200, 530, 204),
    'a sample on the way to the dispatched point is part of the stroke');
  check(!sampleOnSegment(500, 200, 560, 200, 230, 200),
    'a sample off that segment is not');
  check(!sampleOnSegment(500, 200, 560, 200, 400, 200),
    'and neither is one back toward where the pointer is not');
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
