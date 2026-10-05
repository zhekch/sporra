import { writeFileSync, readFileSync } from 'node:fs';
import { alphaLut } from '../../sporra-webserver/src/blob-canvas.js';
const file = new URL('../test/blob-vectors.json', import.meta.url);
const data = JSON.stringify(Object.fromEntries([0.1, 0.2, 0.3, 0.8].map(edge => [edge, [...alphaLut(edge)]]))) + '\n';
if (process.argv.includes('--check')) {
  if (readFileSync(file, 'utf8') !== data) throw new Error('Blob vectors drifted; regenerate them');
} else writeFileSync(file, data);
