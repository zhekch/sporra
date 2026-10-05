// Pure ranking and date queries shared with the native search API.
import { fold, matchRank } from './fold.js';
import { dayKey } from './trips.js';
import { MONTHS } from './calendar-data.js';

const MONTH_AT = (word) => {
  const w = String(word).toLowerCase();
  // Whole names first, so "mar" can't be beaten by "March" losing to "May" —
  // and abbreviations only when exactly one month starts that way, so "ju" is
  // no month at all rather than quietly meaning June.
  const exact = MONTHS.findIndex((n) => n.toLowerCase() === w);
  if (exact >= 0) return exact;
  const hits = MONTHS.map((n, i) => [n, i]).filter(([n]) => n.toLowerCase().startsWith(w));
  return hits.length === 1 ? hits[0][1] : -1;
};
const pad = (n) => String(n).padStart(2, '0');
const dayOk = (mi, d) => d >= 1 && d <= [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mi];

export function parseDateQuery(text) {
  const q = String(text ?? '').trim().replace(/,/g, ' ').replace(/\s+/g, ' ');
  if (!q) return null;
  let m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(q);
  if (m) return `${m[1]}-${pad(+m[2])}-${pad(+m[3])}`;
  m = /^(\d{4})-(\d{1,2})$/.exec(q);
  if (m) return `${m[1]}-${pad(+m[2])}`;
  // 12.08.2024 and 12/08/2024 — day first, as written everywhere this app is
  // likely to be read.
  m = /^(\d{1,2})[./](\d{1,2})[./](\d{4})$/.exec(q);
  if (m) return `${m[3]}-${pad(+m[2])}-${pad(+m[1])}`;

  // Everything with the month spelled out, in any order people write it:
  // "october 15", "15 october", "october 15 2025", "2025 october 15",
  // "october 2025", "2025 october", "october".
  const words = q.split(' ');
  const monthWord = words.findIndex((w) => /^[a-zA-Z]{3,}$/.test(w) && MONTH_AT(w) >= 0);
  if (monthWord >= 0 && words.every((w, i) => i === monthWord || /^\d{1,4}$/.test(w))) {
    const mi = MONTH_AT(words[monthWord]);
    const nums = words.filter((_, i) => i !== monthWord).map(Number);
    if (nums.length > 2) return null;
    const year = nums.find((n) => n >= 1000);
    const day = nums.find((n) => n < 1000);
    if (nums.some((n) => n >= 1000 && (n < 1990 || n > 2100))) return null;
    if (day !== undefined && !dayOk(mi, day)) return null;
    if (year !== undefined && day !== undefined) return `${year}-${pad(mi + 1)}-${pad(day)}`;
    if (year !== undefined) return `${year}-${pad(mi + 1)}`;
    if (day !== undefined) return `--${pad(mi + 1)}-${pad(day)}`;
    return `--${pad(mi + 1)}`;
  }

  // A bare year is a month query for January… but reading "2024" as a date at
  // all would swallow every text search for a number, so it stays a year.
  if (/^\d{4}$/.test(q) && +q >= 1990 && +q <= 2100) return q;
  return null;
}

// Everything a trip is findable by, in the order of how much each says about
// where the trip *was*. The name is what it is called; the tags are everywhere
// it merely went.
const TRIP_FIELDS = [(t) => t.name, (t) => t.place, (t) => t.region, (t) => t.country,
  (t) => (t.tags ?? []).join(' ')];

/**
 * How well a trip answers a typed query — lower is better, `Infinity` for no
 * match at all. Which field matched, and then how much of that field the query
 * was, so an exact name beats a name starting with it, which beats a name
 * containing it, which beats the same three on the canton underneath.
 *
 * Sorted on before anything else, because the alternative was sorting matches by
 * date: a fortnight actually spent in Zürich came out below a weekend in
 * St. Moritz that had merely driven through it, and the list gave no clue why.
 *
 * @param {object} t a derived trip
 * @param {string} q the query, already folded (src/fold.js)
 */
export function tripRelevance(t, q) {
  if (!q) return 0;
  let best = Infinity;
  for (let i = 0; i < TRIP_FIELDS.length; i++) {
    const rank = matchRank(fold(TRIP_FIELDS[i](t)), q);
    if (rank >= 0 && i * 3 + rank < best) best = i * 3 + rank;
  }
  return best;
}

/**
 * Was this trip happening during that month, or that year?
 *
 * A trip is a span, so this is an overlap and not a lookup: the fortnight that
 * started on the 28th of August belongs to September as much as to August, and
 * somebody typing "September 2023" is asking what they were doing then — not
 * which trips happened to begin in it.
 *
 * Compared on the *prefix* of each end's day key, which is the whole reason
 * dates are written biggest-part-first: `"2023-08" <= "2023-09"` is true and
 * `"2023-10" <= "2023-09"` is not, with no arithmetic and no month lengths. Both
 * ends are keyed by `dayKey`, the same function the calendar keys its days with,
 * so a trip cannot land in one and not the other.
 *
 * @param {{start:number, end:number}} t a derived trip
 * @param {string} period `YYYY` or `YYYY-MM`
 */
export function tripInPeriod(t, period) {
  const n = period.length;
  return dayKey(t.start).slice(0, n) <= period && dayKey(t.end).slice(0, n) >= period;
}
