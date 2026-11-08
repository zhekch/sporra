import { writeFileSync, readFileSync } from 'node:fs';
import strings from '../../sporra-webserver/src/locales/en.js';
const url = new URL('../assets/app_en.arb', import.meta.url);
const content = JSON.stringify({ '@@locale': 'en', ...strings }, null, 2) + '\n';
if (process.argv.includes('--check')) {
  if (readFileSync(url, 'utf8') !== content) throw new Error('Run node Tools/gen-arb.mjs to refresh English strings');
} else writeFileSync(url, content);
