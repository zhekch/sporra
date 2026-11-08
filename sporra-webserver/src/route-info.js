import { graphValue, formatGraphSpeed, formatMetres, formatAxisTime, graphTimeStep, graphData } from './route-graph.js';
export { formatGraphSpeed, graphTimeStep } from './route-graph.js';
// The card you get by tapping a saved route on the map: what it was, when, how
// far. Two ways on from here — zoom to it, or open it properly.
//
// It used to carry Edit and Remove as well, which made it a third place that
// knew how to change a route. Everything that *changes* one now lives in the
// routes dialog (Routes and statistics → a route), and "More info" is the door
// to it; this card stays a read-only glance at the line you just tapped.
//
// Same shape and language as the cell card (src/cell-info.js); main.js owns the
// route list and hands over one plain object. The graph and the two pills are
// the one thing this card draws that the cell card does not: speed or
// elevation along the line, scrubbed from here or from the map.

import { formatDistance, formatDuration, recordedSeconds, routeSamples } from './routes.js';
import { formatTime } from './clock.js';
import { metricColor, metricDomain, spanValue } from './route-metric.js';
import { t } from './i18n.js';

const dayFmt = new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
const NS = 'http://www.w3.org/2000/svg';
// Tall enough to read a climb, short enough that the card still fits over a phone.
// The high, the low and the clock sit outside this, in the rows around it.
const GRAPH_H = 72;

const day = (sec) => (sec ? dayFmt.format(new Date(sec * 1000)) : null);
const clock = (sec) => (sec ? formatTime(sec * 1000) : null);

// One row. A track that ran past midnight names both ends; one that did not
// is a single day, and the clock belongs on that same line.
function whenLine(r) {
  const started = day(r.firstAt);
  if (!started) return null;
  const ended = day(r.lastAt);
  const startClock = clock(r.firstAt);
  const endClock = clock(r.lastAt);
  if (ended && started !== ended && r.lastAt > r.firstAt) {
    const a = startClock ? `${started}, ${startClock}` : started;
    const b = endClock ? `${ended}, ${endClock}` : ended;
    return `${a} – ${b}`;
  }
  return startClock ? `${started}, ${startClock}` : started;
}

function readout(className, values) {
  const row = document.createElement('div');
  row.className = `route-metric-readout ${className}`;
  for (const value of values) {
    const span = document.createElement('span');
    span.textContent = value;
    row.append(span);
  }
  return row;
}

/**
 * Draw one activity's graph into `graphEl`: the high value, the line, the low
 * value, and — when the activity has a clock — the time since the start.
 *
 * @returns {{dot:SVGCircleElement, graphMap:object}|null}
 */
export function fillMetricGraph(graphEl, samples, metric) {
  graphEl.replaceChildren();
  if (!metric) return null;
  // Time, when the activity has one: the numbers under the line are minutes
  // and hours, and the line has to be drawn against the same clock or a
  // pause would sit in the wrong place. Distance is the fallback for a
  // trace that kept heights and lost its times.
  const graph = graphData(samples, metric);
  if (!graph) return null;
  const { byTime, runs } = graph;
  const endSec = byTime ? graph.maxX : 0;
  const xOf = (s) => !s ? null : byTime ? s.elapsed : s.distM;
  graphEl.setAttribute(
    'aria-label',
    metric === 'elev' ? t('route-metric-graph.elevation') : t('route-metric-graph.speed'),
  );
  const w = Math.max(1, graphEl.clientWidth);
  const h = GRAPH_H;
  const padX = 2;
  const padY = 6;
  const minY = graph.min;
  const maxY = graph.max;
  const spanY = maxY - minY || 1;
  const maxX = graph.maxX;
  const spanX = maxX || 1;
  const X = (x) => padX + (x / spanX) * (w - padX * 2);
  const Y = (y) => padY + (1 - (y - minY) / spanY) * (h - padY * 2);
  const value = metric === 'elev' ? formatMetres : formatGraphSpeed;
  const domain = metricDomain(samples, metric);
  const colorOf = (index) => {
    if (!domain) return null;
    const v = spanValue(samples, metric, index);
    if (v == null || !Number.isFinite(v)) return null;
    const unit = domain.flat || domain.hi === domain.lo
      ? 0.5
      : Math.min(1, Math.max(0, (v - domain.lo) / (domain.hi - domain.lo)));
    return metricColor(metric, unit);
  };
  const graphMap = {
    X,
    Y,
    xOf,
    invert: (px) => ((px - padX) / (w - padX * 2)) * spanX,
  };

  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
  svg.setAttribute('width', String(w));
  svg.setAttribute('height', String(h));
  const base = h - 1;
  // The same colours as the line on the map, one span at a time. A single
  // gradient would restart the ramp on the whole graph, which is the reason
  // the map does not use one either.
  if (byTime) {
    const step = graphTimeStep(endSec);
    for (let t = step; t < endSec; t += step) {
      const tick = document.createElementNS(NS, 'line');
      const x = X(t).toFixed(1);
      tick.setAttribute('x1', x);
      tick.setAttribute('x2', x);
      tick.setAttribute('y1', '0');
      tick.setAttribute('y2', String(h));
      tick.setAttribute('class', 'route-metric-tick');
      svg.append(tick);
    }
  }
  for (const run of runs) {
    for (let n = 1; n < run.length; n++) {
      const a = run[n - 1];
      const b = run[n];
      const color = colorOf(b.i);
      const x1 = X(a.x).toFixed(1);
      const y1 = Y(a.y).toFixed(1);
      const x2 = X(b.x).toFixed(1);
      const y2 = Y(b.y).toFixed(1);
      const fill = document.createElementNS(NS, 'path');
      fill.setAttribute('d', `M${x1} ${y1} L${x2} ${y2} L${x2} ${base} L${x1} ${base} Z`);
      fill.setAttribute('class', 'route-metric-fill');
      if (color) fill.setAttribute('fill', color);
      const line = document.createElementNS(NS, 'path');
      line.setAttribute('d', `M${x1} ${y1} L${x2} ${y2}`);
      line.setAttribute('class', 'route-metric-line');
      if (color) line.setAttribute('stroke', color);
      svg.append(fill, line);
    }
  }
  const dot = document.createElementNS(NS, 'circle');
  dot.setAttribute('r', '4.5');
  dot.setAttribute('class', 'route-metric-dot');
  dot.style.display = 'none';
  svg.append(dot);
  const maxLabel = value(maxY);
  const minLabel = value(minY);
  if (maxLabel) graphEl.append(readout('is-max', [maxLabel]));
  graphEl.append(svg);
  // One row under the line. The low reading takes the left, where 0 min
  // used to be, and the hour marks sit on that same row. The total is
  // already the Duration line, so the graph does not say it again.
  const axis = axisReadout(minLabel, byTime ? endSec : 0, X, w);
  if (axis) graphEl.append(axis);
  return { dot, graphMap };
}

// A label is about this wide per character at 11px. The old rule kept 46px
// clear of the right edge, which was where the total used to sit. The total
// is gone, so that gap was hiding 8 h, and 30 min on a short run, while the
// line for both was still drawn.
const LABEL_CHAR_PX = 6.2;

function axisReadout(minLabel, endSec, X, width) {
  const row = document.createElement('div');
  row.className = 'route-metric-readout is-axis';
  if (minLabel) {
    const span = document.createElement('span');
    span.className = 'is-value';
    span.textContent = minLabel;
    row.append(span);
  }
  if (!(endSec > 0)) return minLabel ? row : null;
  const step = graphTimeStep(endSec);
  const reserved = minLabel ? minLabel.length * LABEL_CHAR_PX + 8 : 0;
  let prevRight = reserved;
  let any = false;
  for (let t = step; t < endSec; t += step) {
    const x = X(t);
    const label = formatAxisTime(t);
    if (!label) continue;
    const half = (label.length * LABEL_CHAR_PX) / 2;
    // Centred on its line. Skip only when the word would cover the low
    // reading, the previous word, or run off the card.
    if (x - half < prevRight || x + half > width) continue;
    const span = document.createElement('span');
    span.className = 'is-tick';
    span.textContent = label;
    span.style.left = `${x}px`;
    row.append(span);
    prevRight = x + half + 4;
    any = true;
  }
  return minLabel || any ? row : null;
}

/**
 * Wires the card (markup lives in index.html).
 * @param {object} opts
 * @param {() => void} opts.onClose
 * @param {(route:object) => void} opts.onZoom
 * @param {(route:object) => void} opts.onMore  open it in the routes dialog
 * @param {(metric:'speed'|'elev'|null) => void} [opts.onMetric]
 * @param {(index:number) => void} [opts.onScrub] a point picked on the graph
 */
export function mountRouteInfo({ onClose, onZoom, onMore, onMetric, onScrub } = {}) {
  const $ = (id) => document.getElementById(id);
  const card = $('route-info');
  const nameEl = $('route-info-name');
  const subEl = $('route-info-sub');
  const rowsEl = $('route-info-rows');
  const closeBtn = $('route-info-close');
  const zoomBtn = $('route-zoom');
  const moreBtn = $('route-more');
  const pills = $('route-metric-pills');
  const speedBtn = $('route-metric-speed');
  const elevBtn = $('route-metric-elev');
  const graphEl = $('route-metric-graph');
  const emptyEl = $('route-metric-empty');

  let route = null;
  let samples = [];
  /** @type {'speed'|'elev'|null} */
  let metric = null;
  let scrub = -1;
  let dot = null;
  let graphMap = null;
  let dragging = false;

  function hide() {
    card.hidden = true;
    pills.hidden = true;
    graphEl.hidden = true;
    emptyEl.hidden = true;
    route = null;
    samples = [];
    metric = null;
    scrub = -1;
  }

  function row(label, value) {
    if (!value) return;
    const el = document.createElement('div');
    el.className = 'cell-info-row';
    el.innerHTML = '<span></span><b></b>';
    el.firstChild.textContent = label;
    el.lastChild.textContent = value;
    rowsEl.append(el);
  }

  function paintPills() {
    speedBtn.classList.toggle('active', metric === 'speed');
    elevBtn.classList.toggle('active', metric === 'elev');
    speedBtn.setAttribute('aria-pressed', metric === 'speed' ? 'true' : 'false');
    elevBtn.setAttribute('aria-pressed', metric === 'elev' ? 'true' : 'false');
  }

  function placeDot() {
    if (!dot || !graphMap) return;
    const y = graphValue(samples, metric, scrub);
    const x = scrub < 0 ? null : graphMap.xOf(samples[scrub]);
    if (y == null || x == null) {
      dot.style.display = 'none';
      return;
    }
    dot.style.display = '';
    dot.setAttribute('cx', String(graphMap.X(x)));
    dot.setAttribute('cy', String(graphMap.Y(y)));
  }

  function drawGraph() {
    // Unhide before measuring. A hidden graph has no width, and the line
    // would be drawn into a box of nothing.
    if (!metric) {
      graphEl.replaceChildren();
      graphEl.hidden = true;
      dot = null;
      graphMap = null;
      return;
    }
    graphEl.hidden = false;
    const painted = fillMetricGraph(graphEl, samples, metric);
    dot = painted?.dot ?? null;
    graphMap = painted?.graphMap ?? null;
    graphEl.hidden = !painted;
    if (painted) placeDot();
  }

  function indexAt(clientX) {
    const svg = graphEl.querySelector('svg');
    if (!svg || !graphMap || !samples.length) return -1;
    const rect = svg.getBoundingClientRect();
    const width = Number(svg.getAttribute('width'));
    if (!rect.width || !width) return -1;
    const px = ((clientX - rect.left) / rect.width) * width;
    const x = graphMap.invert(px);
    let best = -1;
    let bestD = Infinity;
    for (let i = 0; i < samples.length; i++) {
      const sx = graphMap.xOf(samples[i]);
      if (sx == null) continue;
      const d = Math.abs(sx - x);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  function emitScrub(idx) {
    if (idx < 0) return;
    scrub = idx;
    placeDot();
    onScrub?.(idx);
  }

  function choose(next) {
    if (next === metric) return;
    if (next === 'speed' && speedBtn.disabled) return;
    if (next === 'elev' && elevBtn.disabled) return;
    metric = next;
    paintPills();
    drawGraph();
    onMetric?.(metric);
  }

  function show(r, keepMetric) {
    route = r;
    scrub = -1;
    nameEl.textContent = r.name || 'Activity';
    // The activity and when it was. Place and source used to lead this line,
    // and the same two facts were then repeated as rows.
    const sport = r.sport ? (r.sportGuessed ? `${r.sport} (estimated)` : r.sport) : null;
    subEl.textContent = [sport, whenLine(r)].filter(Boolean).join(' · ');

    rowsEl.replaceChildren();
    row('Distance', formatDistance(r.lengthM));
    // Only shown when the file carried elevation at all — a flat 0 m would read
    // as a measurement rather than an absence.
    if (r.elevUp > 0) row('Climb', `${Math.round(r.elevUp).toLocaleString()} m`);
    row('Duration', formatDuration(recordedSeconds(r)));

    samples = routeSamples(r.geom, r.trace);
    const hasSpeed = samples.some((s) => s.speed != null);
    const hasEle = samples.some((s) => s.ele != null);
    // Stepping to the workout either side keeps the pill you were reading.
    // A fresh tap still opens on speed: nothing was asked to be kept, and a
    // ride with no speed falls through to elevation exactly as before.
    if (keepMetric === 'elev' && hasEle) metric = 'elev';
    else if (keepMetric === 'speed' && hasSpeed) metric = 'speed';
    else metric = hasSpeed ? 'speed' : hasEle ? 'elev' : null;
    speedBtn.disabled = !hasSpeed;
    elevBtn.disabled = !hasEle;
    pills.hidden = !metric;
    emptyEl.hidden = !!metric;
    paintPills();
    // Shown before the graph is measured: a hidden card has no width, and the
    // line would be drawn into a box of nothing.
    card.hidden = false;
    drawGraph();
    onMetric?.(metric);
  }

  // A tap on the line. The card does not tell the map — the map is who asked.
  function setScrub(index) {
    scrub = index;
    placeDot();
  }

  closeBtn.addEventListener('click', () => {
    hide();
    onClose?.();
  });

  zoomBtn.addEventListener('click', () => {
    if (route) onZoom?.(route);
  });

  moreBtn.addEventListener('click', () => {
    if (route) onMore?.(route);
  });

  speedBtn.addEventListener('click', () => choose('speed'));
  elevBtn.addEventListener('click', () => choose('elev'));

  graphEl.addEventListener('pointerdown', (e) => {
    if (!metric) return;
    dragging = true;
    graphEl.setPointerCapture(e.pointerId);
    emitScrub(indexAt(e.clientX));
  });
  graphEl.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    emitScrub(indexAt(e.clientX));
  });
  const stopDrag = () => {
    dragging = false;
  };
  graphEl.addEventListener('pointerup', stopDrag);
  graphEl.addEventListener('pointercancel', stopDrag);

  return {
    show,
    hide,
    setScrub,
    visible: () => !card.hidden,
    current: () => route,
    metric: () => metric,
    scrubIndex: () => scrub,
  };
}
