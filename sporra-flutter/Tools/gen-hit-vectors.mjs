import { writeFileSync } from 'node:fs';
import { pointToCell, normCol, colsOf, mercX, mercY, cellCenter, project } from '../../sporra-webserver/src/hexgrid.js';
const points = [[0,0],[-179.999,0],[179.999,0],[-8.2,47],[8.28,46.95],[120,-70],[-120,70],[0,85.051128],[0,-85.051128]];
const vectors = [];
for (let level=0; level<6; level++) {
  for (const [lng,lat] of [...points, ...[-2,-1,0,1,2].map(c => project(cellCenter(level,c,-2)))]) {
    const [col,row]=pointToCell(level,mercX(lng),mercY(lat));
    vectors.push([level,lng,lat,`${normCol(col,colsOf(level))}/${row}`]);
  }
}
writeFileSync(new URL('../test/hit-vectors.json',import.meta.url), JSON.stringify(vectors));
