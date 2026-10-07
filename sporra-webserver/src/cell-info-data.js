import { normalizeVisitDates } from './visit-dates.js';
// Visit facts shown by both the web and native info cards.
export function summarizeCells(ids, cellMeta) {
  let addedAt = 0;
  let firstAt = 0;
  let lastAt = 0;
  let hits = 0;
  const earlier = (a, b) => (b && (!a || b < a) ? b : a); // 0 means "unknown"
  for (const id of ids) {
    for (const m of cellMeta.get(id) ?? []) {
      // Only imported data has a meaningful count — a hand-marked cell carries
      // a placeholder 1 that would be nonsense to show.
      if (m.source !== 'manual' && m.source !== 'unknown') hits += m.hits || 0;
      addedAt = earlier(addedAt, m.addedAt);
      firstAt = earlier(firstAt, m.firstAt);
      lastAt = Math.max(lastAt, m.lastAt || 0);
    }
  }
  // Neither `fixes` nor the per-source breakdown is rolled up. Both are still
  // stored — the import, sync and Sources screens report them — but as facts
  // about a place they answer questions about the recording rather than about
  // where you were: how often a recorder sampled, and which app was running.
  // The number of cells is not rolled up either, and for the same reason: it
  // was a count of the storage's own units, and the card that used to lead with
  // it says how much ground and how much of the place instead.
  return { hits, addedAt, firstAt, lastAt };
}

// Legacy records only have endpoints; newer imports retain every measured day.
// Never fill the interval between endpoints with invented visits.
export function recordedVisitDates(ids, cellMeta) {
  const days = new Set();
  for (const id of ids) {
    for (const m of cellMeta.get(id) ?? []) {
      if (m.source === 'manual' || m.source === 'unknown') continue;
      for (const day of normalizeVisitDates([...(m.visitDates ?? []), m.firstAt, m.lastAt])) days.add(day);
    }
  }
  return [...days].sort().reverse();
}
