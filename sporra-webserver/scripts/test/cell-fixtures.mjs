// Complete sparse test evidence in the current cell wire schema. Empty arrays
// explicitly mean that the fixture has no additional measured dates/times.
export function cellFixtures(body) {
  if (!body) return body;
  if (Array.isArray(body.cells) && typeof body.source === 'string') return { ...body, cells: body.cells.map(c => {
    const row = Array.isArray(c) ? c : [c.id, c.first, c.last, c.hits, c.fixes, c.visitDates, c.visitTimes];
    return [...row.slice(0, 5), row[5] ?? [], row[6] ?? []];
  }) };
  if (Array.isArray(body.rows)) return { ...body, rows: body.rows.map(r => {
    const row = Array.isArray(r) ? r : [r.id, r.source, r.addedAt, r.firstAt, r.lastAt, r.hits, r.fixes, r.visitDates, r.visitTimes];
    return [...row.slice(0, 7), row[7] ?? [], row[8] ?? []];
  }) };
  return body;
}
