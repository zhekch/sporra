import { normCol } from './hexgrid.js';

// At most one neighbour needs the isolated-cell pixel floor.
const SPARSE_NEIGHBOURS = 1;

// The six neighbours of a cell, by column parity. Flat-top, odd-q: odd columns
// sit half a row north, so which two rows the next column along contributes
// depends on which parity you are standing on. Column counts are even at every
// level by construction (see BASE_COLS), so a world copy never changes a
// column's parity and the canonical column can be asked directly.
const NEIGHBOURS_ODD = [[0, -1], [0, 1], [-1, 0], [-1, 1], [1, 0], [1, 1]];
const NEIGHBOURS_EVEN = [[0, -1], [0, 1], [-1, -1], [-1, 0], [1, -1], [1, 0]];

export function sparseCell(cells, columns, col, row) {
  let n = 0;
  for (const [dc, dr] of col & 1 ? NEIGHBOURS_ODD : NEIGHBOURS_EVEN) {
    if (cells.has(`${normCol(col + dc, columns)}/${row + dr}`) && ++n > SPARSE_NEIGHBOURS) return false;
  }
  return true;
}
