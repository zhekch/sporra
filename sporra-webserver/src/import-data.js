// Container and format parsing shared by browser and native uploads.
import { parseLocationFile } from './locations.js';
import { isZip, isGzip, unzip, gunzip, stripCompressedExt } from './archive.js';
import { parseFit, looksLikeFit } from './fit.js';

const IMPORTABLE = /\.(gpx|tcx|kml|geojson|json|csv|tsv|txt|fit)(\.gz)?$/i;

/**
 * One dropped file → the list of real files inside it.
 * @returns {Promise<{items: Array<{name, bytes}>, source: string|null}>}
 */
export async function expand(file) {
  const bytes = new Uint8Array(await file.arrayBuffer());

  if (isZip(bytes)) {
    const entries = await unzip(bytes, { filter: (n) => IMPORTABLE.test(n) });
    if (!entries.length) throw new Error(`${file.name} has no location files in it.`);
    // Strava lays its export out as activities/<id>.<ext>; recognizing that is
    // what lets a whole archive land under the Strava source rather than as a
    // pile of anonymous GPX and FIT files. It also narrows what's worth
    // opening: the archive's own activities.csv is an index, not a track, and
    // reporting it as an unreadable file would be noise.
    const activities = entries.filter((e) => /(^|\/)activities\//i.test(e.name));
    const source = activities.length ? 'strava' : null;
    const items = [];
    for (const e of source ? activities : entries) {
      items.push({
        name: stripCompressedExt(e.name),
        bytes: isGzip(e.bytes) ? await gunzip(e.bytes) : e.bytes,
      });
    }
    return { items, source };
  }

  if (isGzip(bytes)) {
    return { items: [{ name: stripCompressedExt(file.name), bytes: await gunzip(bytes) }], source: null };
  }
  return { items: [{ name: file.name, bytes }], source: null };
}

// FIT is binary, everything else this reads is text.
export function parseExpanded(name, bytes) {
  if (looksLikeFit(bytes)) {
    const { points, sport } = parseFit(bytes);
    const track = { name: '', segments: [points], firstAt: 0, lastAt: 0, sport: sport || '' };
    return { source: 'fit', format: 'FIT', points, tracks: points.length >= 2 ? [track] : [] };
  }
  return parseLocationFile(name, new TextDecoder().decode(bytes));
}
