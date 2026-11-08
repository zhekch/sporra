// DOM-free graph readings shared by the web card and native render API.
import { metricDomain, metricColor, spanValue } from './route-metric.js';

// Elevation is the point's own. Speed is the span that arrived here, or, at
// the first point of a segment, the span that leaves — a segment has no
// incoming speed, and the graph would otherwise open with a hole.
export function graphValue(samples, metric, index) {
  const s = samples[index];
  if (!s) return null;
  if (metric === 'elev') return s.ele;
  if (s.speed != null) return s.speed;
  const next = samples[index + 1];
  if (next && next.seg === s.seg && next.speed != null) return next.speed;
  return null;
}

// The same rounding the dot on the map uses, so the axis and the label agree.
// A stop is not a reading: 0 km/h, and the 0.1 km/h a crawl rounds to, are
// left off. Showing either of them is what made the start of a ride look measured.
export function formatGraphSpeed(ms) {
  if (ms == null || !Number.isFinite(ms) || ms <= 0) return null;
  const kmh = ms * 3.6;
  const text = kmh < 10 ? kmh.toFixed(1) : String(Math.round(kmh));
  if (text === '0' || text === '0.0' || text === '0.1') return null;
  return `${text} km/h`;
}

export function formatMetres(m) {
  const rounded = Math.abs(m) >= 10 ? Math.round(m) : Math.round(m * 10) / 10;
  return `${rounded} m`;
}

// Minutes and hours only. Zero is not a label — the line already starts at
// the left edge — and a few seconds still reads as a minute, because a blank
// end would say the clock was never kept.
export function formatAxisTime(sec) {
  if (!(sec > 0)) return null;
  const totalMin = Math.round(sec / 60);
  const shown = totalMin === 0 ? 1 : totalMin;
  const h = Math.floor(shown / 60);
  const m = shown % 60;
  if (h && m) return `${h} h ${m} min`;
  if (h) return `${h} h`;
  return `${shown} min`;
}

// A short activity is marked every quarter hour. Past two hours that is a
// fence of lines, so the mark becomes the hour.
export function graphTimeStep(endSec) {
  return endSec <= 2 * 3600 ? 15 * 60 : 3600;
}

export function runsOf(samples, metric, xOf) {
  const runs = [];
  let run = [];
  const cut = () => {
    if (run.length) runs.push(run);
    run = [];
  };
  for (let i = 0; i < samples.length; i++) {
    const y = graphValue(samples, metric, i);
    const prev = samples[i - 1];
    if (prev && prev.seg !== samples[i].seg) cut();
    const x = xOf(samples[i]);
    if (y == null || x == null) {
      cut();
      continue;
    }
    run.push({ i, x, y });
  }
  cut();
  return runs;
}


export function graphData(samples, metric) {
  const endSec = samples.reduce((m, s) => s.elapsed > m ? s.elapsed : m, 0);
  const byTime = endSec > 0;
  const runs = runsOf(samples, metric, s => byTime ? s.elapsed : s.distM);
  const values = runs.flat().map(p => p.y);
  if (!values.length) return null;
  const domain = metricDomain(samples, metric);
  const value = metric === 'elev' ? formatMetres : formatGraphSpeed;
  for (const run of runs) for (const p of run) {
    const v = spanValue(samples, metric, p.i);
    const unit = !domain || domain.flat || domain.hi === domain.lo ? 0.5 : Math.min(1, Math.max(0, (v - domain.lo) / (domain.hi - domain.lo)));
    p.color = v == null ? null : metricColor(metric, unit);
    p.label = value(p.y);
  }
  const min = values.reduce((m, v) => Math.min(m, v), Infinity);
  const max = values.reduce((m, v) => Math.max(m, v), -Infinity);
  const ticks = [];
  if (byTime) for (let t = graphTimeStep(endSec); t < endSec; t += graphTimeStep(endSec)) ticks.push({ x: t, label: formatAxisTime(t) });
  return { metric, byTime, min, max, minLabel: value(min), maxLabel: value(max), maxX: byTime ? endSec : samples.at(-1)?.distM || 1, runs, ticks };
}
