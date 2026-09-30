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

import { sourceLabel } from './locations.js';
import { formatDistance, formatDuration, recordedSeconds, routeSamples } from './routes.js';
import { formatTime } from './clock.js';
import { t } from './i18n.js';

const dayFmt = new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
const NS = 'http://www.w3.org/2000/svg';
// Tall enough to read a climb, short enough that the card still fits over a phone.
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

// Elevation is the point's own. Speed is the span that arrived here, or, at
// the first point of a segment, the span that leaves — a segment has no
// incoming speed, and the graph would otherwise open with a hole.
function graphValue(samples, metric, index) {
  const s = samples[index];
  if (!s) return null;
  if (metric === 'elev') return s.ele;
  if (s.speed != null) return s.speed;
  const next = samples[index + 1];
  if (next && next.seg === s.seg && next.speed != null) return next.speed;
  return null;
}

function runsOf(samples, metric) {
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
    if (y == null) {
      cut();
      continue;
    }
    run.push({ i, x: samples[i].distM, y });
  }
  cut();
  return runs;
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
    if (scrub < 0 || y == null) {
      dot.style.display = 'none';
      return;
    }
    dot.style.display = '';
    dot.setAttribute('cx', String(graphMap.X(samples[scrub].distM)));
    dot.setAttribute('cy', String(graphMap.Y(y)));
  }

  function drawGraph() {
    graphEl.replaceChildren();
    dot = null;
    graphMap = null;
    if (!metric) {
      graphEl.hidden = true;
      return;
    }
    const runs = runsOf(samples, metric);
    const ys = runs.flat().map((p) => p.y);
    if (!ys.length) {
      graphEl.hidden = true;
      return;
    }
    graphEl.hidden = false;
    graphEl.setAttribute(
      'aria-label',
      metric === 'elev' ? t('route-metric-graph.elevation') : t('route-metric-graph.speed'),
    );
    const w = Math.max(1, graphEl.clientWidth);
    const h = GRAPH_H;
    const padX = 3;
    const padY = 7;
    const maxX = samples[samples.length - 1]?.distM || 1;
    const minY = Math.min(...ys);
    const spanY = Math.max(...ys) - minY || 1;
    const X = (x) => padX + (x / maxX) * (w - padX * 2);
    const Y = (y) => padY + (1 - (y - minY) / spanY) * (h - padY * 2);
    graphMap = { X, Y };

    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
    svg.setAttribute('width', String(w));
    svg.setAttribute('height', String(h));
    const base = h - 1;
    for (const run of runs) {
      if (run.length < 2) continue;
      const d = run.map((p, n) => `${n ? 'L' : 'M'}${X(p.x).toFixed(1)} ${Y(p.y).toFixed(1)}`).join(' ');
      const fill = document.createElementNS(NS, 'path');
      fill.setAttribute('d', `${d} L${X(run[run.length - 1].x).toFixed(1)} ${base} L${X(run[0].x).toFixed(1)} ${base} Z`);
      fill.setAttribute('class', 'route-metric-fill');
      const line = document.createElementNS(NS, 'path');
      line.setAttribute('d', d);
      line.setAttribute('class', 'route-metric-line');
      svg.append(fill, line);
    }
    dot = document.createElementNS(NS, 'circle');
    dot.setAttribute('r', '4.5');
    dot.setAttribute('class', 'route-metric-dot');
    svg.append(dot);
    graphEl.append(svg);
    placeDot();
  }

  function indexAt(clientX) {
    const svg = graphEl.querySelector('svg');
    if (!svg || !samples.length) return -1;
    const rect = svg.getBoundingClientRect();
    if (!rect.width) return -1;
    const u = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    const maxX = samples[samples.length - 1].distM || 1;
    const dist = u * maxX;
    let best = 0;
    let bestD = Infinity;
    for (let i = 0; i < samples.length; i++) {
      const d = Math.abs(samples[i].distM - dist);
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

  function show(r) {
    route = r;
    scrub = -1;
    nameEl.textContent = r.name || 'Route';
    const started = day(r.firstAt);
    // The place is the most useful thing to know at a glance, so it leads the
    // sub-line — unless it *is* the title, in which case repeating it is noise.
    const place = r.place && r.place !== r.name ? r.place : null;
    subEl.textContent = [place, sourceLabel(r.source), started ?? `added ${day(r.addedAt) ?? 'recently'}`]
      .filter(Boolean)
      .join(' · ');

    rowsEl.replaceChildren();
    // Same wording as the dialog: a worked-out activity says so.
    row('Activity', r.sport ? (r.sportGuessed ? `${r.sport} (estimated)` : r.sport) : '');
    row('Distance', formatDistance(r.lengthM));
    // Only shown when the file carried elevation at all — a flat 0 m would read
    // as a measurement rather than an absence.
    if (r.elevUp > 0) row('Climb', `${Math.round(r.elevUp).toLocaleString()} m`);
    row('When', whenLine(r));
    row('Duration', formatDuration(recordedSeconds(r)));

    samples = routeSamples(r.geom, r.trace);
    const hasSpeed = samples.some((s) => s.speed != null);
    const hasEle = samples.some((s) => s.ele != null);
    metric = hasSpeed ? 'speed' : hasEle ? 'elev' : null;
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
