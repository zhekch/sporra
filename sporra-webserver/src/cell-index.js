// Where the lit cells of one level are, by place rather than by name.
//
// `litSets[L]` answers "is this cell lit?" and nothing else: it is a Map keyed by
// "col/row", so the only way to ask it "what is lit inside this window?" was to
// walk every entry and throw away the ones outside. That was the blob paint's
// loop. On a map of half a million stored cells it parsed half a million keys on
// every repaint at the finest level — 22 ms on a desktop before a single disc
// was drawn — whatever the window held, which on a phone looking at one town was
// a few hundred of them.
//
// So beside each level's Map sits one of these: the same keys, filed into square
// buckets of the lattice, so a window visits only the buckets it overlaps. The
// Map stays the answer to membership and to the stats; this is only ever asked
// where to look.

// Cells per bucket side.
//
// Small enough that a phone's padded viewport at the finest level — a few
// hundred columns across — touches a few dozen buckets and wastes little at the
// edges; large enough that a coarse level, or a zoomed-out window, is not
// visiting thousands of empty ones. The query cost is dominated by the cells it
// returns either way: measured on the half-million-cell account, 0.02 ms for a
// phone window against 22 ms for the scan it replaces.
export const CELL_BUCKET = 64;

// Rows run to about ±270k at the finest level (the Mercator clamp over a row
// spacing of √3·R0), so a bucket row fits in ±8192 with room to spare and a
// bucket column times 2¹⁴ plus the shifted row is an exact integer key. A number
// rather than a string: building the index files every lit cell once, and a
// string per cell is the allocation this whole module exists to avoid.
const ROW_SPAN = 16384;
const ROW_SHIFT = 8192;

const bucketKey = (bc, br) => bc * ROW_SPAN + (br + ROW_SHIFT);

function visit(key, colMin, colMax, rowMin, rowMax, fn) {
  const sep = key.indexOf('/');
  const col = +key.slice(0, sep);
  const row = +key.slice(sep + 1);
  if (col >= colMin && col <= colMax && row >= rowMin && row <= rowMax) fn(key, col, row);
}

/**
 * An empty index. Columns are canonical — the same column the Map's keys are
 * written in — so a caller that draws world copies asks once per copy.
 */
export function createCellIndex() {
  // bucket key → Set of "col/row". Only the key: the column and row are read
  // back out of it for the cells a window actually returns, which is a few
  // thousand at most, rather than held for every cell of the level.
  const buckets = new Map();
  let size = 0;

  function add(key, col, row) {
    const bk = bucketKey(Math.floor(col / CELL_BUCKET), Math.floor(row / CELL_BUCKET));
    let b = buckets.get(bk);
    if (!b) buckets.set(bk, (b = new Set()));
    if (!b.has(key)) size++;
    b.add(key);
  }

  function remove(key, col, row) {
    const bk = bucketKey(Math.floor(col / CELL_BUCKET), Math.floor(row / CELL_BUCKET));
    const b = buckets.get(bk);
    if (!b || !b.delete(key)) return;
    size--;
    if (!b.size) buckets.delete(bk);
  }

  /**
   * Every filed cell with `colMin ≤ col ≤ colMax` and `rowMin ≤ row ≤ rowMax`,
   * in no particular order. Exact, not a superset: the bucket edges are
   * filtered, so a caller can trust the range it asked for.
   *
   * @param {(key:string, col:number, row:number) => void} fn
   */
  function forEachIn(colMin, colMax, rowMin, rowMax, fn) {
    if (!(colMax >= colMin) || !(rowMax >= rowMin)) return;
    const bc0 = Math.floor(colMin / CELL_BUCKET);
    const bc1 = Math.floor(colMax / CELL_BUCKET);
    const br0 = Math.floor(rowMin / CELL_BUCKET);
    const br1 = Math.floor(rowMax / CELL_BUCKET);
    // A window wider than the whole index is cheaper walked as the index —
    // a zoomed-out view at a fine level would otherwise visit every empty
    // bucket of the ocean on its way across.
    if ((bc1 - bc0 + 1) * (br1 - br0 + 1) > buckets.size) {
      for (const b of buckets.values()) {
        for (const key of b) visit(key, colMin, colMax, rowMin, rowMax, fn);
      }
      return;
    }
    for (let bc = bc0; bc <= bc1; bc++) {
      for (let br = br0; br <= br1; br++) {
        const b = buckets.get(bucketKey(bc, br));
        if (!b) continue;
        for (const key of b) visit(key, colMin, colMax, rowMin, rowMax, fn);
      }
    }
  }

  return {
    add,
    remove,
    forEachIn,
    get size() {
      return size;
    },
  };
}

/**
 * Index every key of a level's Map. The keys are canonical "col/row".
 *
 * @param {Map<string, unknown>} cells
 */
export function indexCells(cells) {
  const index = createCellIndex();
  for (const key of cells.keys()) {
    const sep = key.indexOf('/');
    index.add(key, +key.slice(0, sep), +key.slice(sep + 1));
  }
  return index;
}
