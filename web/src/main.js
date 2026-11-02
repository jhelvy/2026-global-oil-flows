import * as d3 from 'd3';
import raw from '../../data/final/flows.json';
import { createSankey, fmtPct } from './sankey.js';
import { createParticles } from './particles.js';
import { createPriceChart } from './priceChart.js';
import { createControls } from './controls.js';
import { showTooltip, hideTooltip, sparkline } from './tooltip.js';

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const fmtLong = d3.utcFormat('%b %-d, %Y');
const parse = d3.utcParse('%Y-%m-%d');
// How long playback stops at an event, by playback speed in ms per day.
const HOLD_SECONDS = { 200: 5.5, 100: 4.5, 50: 3 };
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

function prepare(raw) {
  const nodes = raw.nodes.map((n, index) => ({ ...n, index, inOrder: [], outOrder: [], touchedBy: new Set() }));
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const links = raw.links.map((l, i) => ({
    ...l,
    i,
    side: l.c == null ? 'left' : 'right',
    sNode: byId.get(l.source),
    tNode: byId.get(l.target),
    oNode: byId.get(l.origin),
    baseline: raw.baseline.values[i],
  }));
  const frames = raw.frames.map((f) => ({ ...f, dateObj: parse(f.date), values: Float32Array.from(f.values) }));
  const dates = frames.map((f) => f.dateObj);

  for (const n of nodes) {
    // A route stacks its outgoing bands by origin in the same order as its incoming ones. Each
    // producer's band then enters and leaves at the same height, and reads as one band.
    const out = n.column === 1
      ? (a, b) => a.oNode.index - b.oNode.index || a.tNode.index - b.tNode.index
      : (a, b) => a.tNode.index - b.tNode.index || a.oNode.index - b.oNode.index;
    n.outOrder = links.filter((l) => l.sNode === n).sort(out).map((l) => l.i);
    n.inOrder = links.filter((l) => l.tNode === n).sort((a, b) => a.sNode.index - b.sNode.index || a.oNode.index - b.oNode.index).map((l) => l.i);
    n.valueLinks = n.column === 0 ? n.outOrder : n.inOrder;
    n.series = frames.map((f) => d3.sum(n.valueLinks, (i) => f.values[i]));
    n.max = d3.max(n.series);
    n.baseline = d3.sum(n.valueLinks, (i) => raw.baseline.values[i]);
    n.now = 0;
  }
  for (const l of links) {
    l.sNode.touchedBy.add(l.origin);
    l.tNode.touchedBy.add(l.origin);
  }

  const warIndex = d3.bisectLeft(dates, parse(raw.meta.war_start));
  const events = raw.events
    .map((e) => ({ ...e, dateObj: parse(e.date) }))
    .map((e) => ({ ...e, index: d3.bisectLeft(dates, e.dateObj) }));
  // Events with a description get a line on the chart and stop playback.
  const popups = events.filter((e) => e.detail);
  return { nodes, links, frames, dates, events, popups, warIndex };
}

function renderLegend() {
  const legend = document.getElementById('legend');
  const groups = [
    ['Gulf producers', '--p_saudi'],
    ['Rest of World', '--p_row'],
    ['Americas', '--p_usa'],
    ['Russia', '--p_russia'],
    ['Stored oil', '--p_stock'],
  ];
  legend.innerHTML =
    groups.map(([label, v]) => `<span><i style="background:var(${v})"></i>${label}</span>`).join('') +
    `<span><i class="outline"></i>Jan 1 to Feb 27 average</span>` +
    `<span class="hint">Click a producer to follow its oil.</span>`;
}

function main() {
  const data = prepare(raw);
  const { frames, nodes, links, events, popups, warIndex } = data;
  renderLegend();

  const wrap = document.getElementById('sankey-wrap');
  const sankey = createSankey(document.getElementById('sankey'), data);
  const particles = createParticles(document.getElementById('particles'), data, sankey.geom);
  particles.readColors();

  // Playback state. `cursor` is a fractional frame index, so playback and jumps both
  // move continuously and the diagram never snaps.
  let cursor = 0;
  let playing = false;
  let ended = false;
  let msPerDay = 100;
  let nextPopup = 0;
  let holdLeft = 0;
  let cardEvent = null;
  let jump = null;
  let lastDay = -1;
  let selected = null;
  let hover = null;
  let needsDraw = true;
  const values = new Float32Array(links.length);

  const controls = createControls({
    count: frames.length,
    onPlayToggle: togglePlay,
    onSpeed: (ms) => (msPerDay = ms),
    onSeek: seek,
    onStep: (d) => seek(Math.max(0, Math.min(frames.length - 1, Math.round(cursor) + d))),
  });

  const chart = createPriceChart(document.getElementById('price-chart'), data, {
    onSeek: seek,
    onHover: (i, event) => {
      const f = frames[i];
      const ev = events.filter((e) => e.index === i);
      const html =
        `<div class="tt-title">${fmtLong(f.dateObj)}</div>` +
        `<div class="tt-row"><span>Brent${f.brent_imputed ? ' (last close)' : ''}</span><span>$${f.brent.toFixed(2)}</span></div>` +
        `<div class="tt-row"><span>Hormuz tankers, 7-day avg</span><span>${f.hormuz_tankers_7d.toFixed(1)}</span></div>` +
        ev.map((e) => `<div class="tt-sub">${esc(e.label)}</div>`).join('');
      hover = null;
      showTooltip(html, event.clientX, event.clientY);
    },
    onLeave: hideTooltip,
  });

  // The event card sits beside its line on the chart, on the side with more room.
  const chartWrap = document.querySelector('.chart-wrap');
  const card = document.getElementById('event-card');

  function placeCard() {
    if (!cardEvent) return;
    const w = chartWrap.clientWidth;
    const lineX = chart.xOf(cardEvent.index);
    const cardW = card.offsetWidth;
    // The right side leaves room for the playhead's value tags.
    const left = lineX + 44 + cardW <= w ? lineX + 44 : lineX - 10 - cardW;
    card.style.left = `${Math.max(0, left)}px`;
  }

  function showCard(ev) {
    cardEvent = ev;
    card.innerHTML =
      `<div class="card-date">${fmtLong(ev.dateObj)}</div>` +
      `<div class="card-title">${esc(ev.label)}</div>` +
      `<p>${esc(ev.detail)}</p>` +
      `<a href="${esc(ev.url)}" target="_blank" rel="noopener">Source</a>`;
    card.hidden = false;
    placeCard();
    chart.setActive(ev);
  }

  function hideCard() {
    cardEvent = null;
    card.hidden = true;
    chart.setActive(null);
  }

  // A reader who lands on an event by hand sees its card too, without any timed stop.
  function syncCard() {
    const day = Math.round(cursor);
    const ev = popups.find((e) => e.index === day);
    if (ev) showCard(ev);
    else hideCard();
  }

  function setState() {
    controls.setState(playing ? 'playing' : ended ? 'ended' : 'paused');
  }

  function togglePlay() {
    if (ended) {
      cursor = 0;
      ended = false;
      nextPopup = 0;
    }
    playing = !playing;
    jump = null;
    holdLeft = 0;
    // Pausing during a stop keeps the card up for reading. Playing again moves on.
    if (playing) hideCard();
    setState();
  }

  function seek(i) {
    playing = false;
    ended = false;
    holdLeft = 0;
    nextPopup = d3.bisectRight(popups.map((e) => e.index), i);
    setState();
    if (reduceMotion) {
      cursor = i;
      jump = null;
      applyCursor();
      syncCard();
    } else {
      jump = { from: cursor, to: i, t: 0 };
    }
    needsDraw = true;
  }

  function applyCursor() {
    const i0 = Math.floor(cursor);
    const i1 = Math.min(i0 + 1, frames.length - 1);
    const a = cursor - i0;
    const va = frames[i0].values;
    const vb = frames[i1].values;
    for (let i = 0; i < values.length; i++) values[i] = va[i] + a * (vb[i] - va[i]);
    sankey.update(values);
    chart.setCursor(cursor);
    const day = Math.round(cursor);
    if (day !== lastDay) onDay(day);
  }

  function onDay(day) {
    lastDay = day;
    const f = frames[day];
    sankey.updateLabels(day);
    document.getElementById('date-value').textContent = fmtLong(f.dateObj);
    controls.setDay(day, fmtLong(f.dateObj));
    if (hover) renderHover();
    if (tableDetails.open) renderTable(day);
  }

  // Table view: the same values as the diagram, reachable without pointer or color.
  const tableDetails = document.getElementById('table-details');
  tableDetails.addEventListener('toggle', () => tableDetails.open && renderTable(Math.round(cursor)));
  function renderTable(day) {
    const col = ['Producer', 'Route', 'Consumer'];
    const rows = nodes
      .map((n) => {
        const now = n.series[day];
        return `<tr><td>${col[n.column]}</td><td>${esc(n.label)}</td><td>${now.toFixed(2)}</td><td>${n.baseline.toFixed(2)}</td><td>${fmtPct(now, n.baseline) || 'n/a'}</td></tr>`;
      })
      .join('');
    document.getElementById('values-table').innerHTML =
      `<caption>${fmtLong(frames[day].dateObj)}</caption>` +
      `<thead><tr><th>Column</th><th>Node</th><th>Today, mb/d</th><th>Jan 1 to Feb 27, mb/d</th><th>Change</th></tr></thead><tbody>${rows}</tbody>`;
  }

  // Hover and selection.
  let pointer = { x: 0, y: 0 };
  function renderHover() {
    if (!hover) return;
    const day = Math.round(cursor);
    if (hover.type === 'link') {
      const l = hover.link;
      const now = frames[day].values[l.i];
      const title =
        l.side === 'left'
          ? `${esc(l.sNode.label)} → ${esc(l.tNode.label)}`
          : `${esc(l.oNode.label)} → ${esc(l.tNode.label)}`;
      const sub = l.side === 'right' ? `<div class="tt-sub">via ${esc(l.sNode.label)}</div>` : '';
      showTooltip(
        `<div class="tt-title">${title}</div>${sub}` +
          `<div class="tt-row"><span>${fmtLong(frames[day].dateObj)}</span><span>${now.toFixed(2)} mb/d</span></div>` +
          `<div class="tt-row"><span>Jan 1 to Feb 27</span><span>${l.baseline.toFixed(2)} mb/d</span></div>` +
          `<div class="tt-row"><span>Change</span><span>${fmtPct(now, l.baseline) || 'n/a'}</span></div>`,
        pointer.x,
        pointer.y
      );
    } else {
      const n = hover.node;
      const now = n.series[day];
      showTooltip(
        `<div class="tt-title">${esc(n.label)}</div>` +
          (n.note ? `<div class="tt-sub">${esc(n.note)}</div>` : '') +
          `<div class="tt-row"><span>${fmtLong(frames[day].dateObj)}</span><span>${now.toFixed(2)} mb/d</span></div>` +
          `<div class="tt-row"><span>Jan 1 to Feb 27</span><span>${n.baseline.toFixed(2)} mb/d</span></div>` +
          `<div class="tt-row"><span>Change</span><span>${fmtPct(now, n.baseline) || 'n/a'}</span></div>` +
          sparkline(n.series, n.baseline, day, warIndex),
        pointer.x,
        pointer.y
      );
    }
  }

  function setHover(h) {
    const same = h?.type === hover?.type && h?.link === hover?.link && h?.node === hover?.node;
    if (same && !h) return;
    hover = h;
    if (!same) sankey.setHighlight(selected, h?.type === 'link' ? h.link : null);
    if (h) renderHover();
    else hideTooltip();
  }

  function select(origin) {
    selected = selected === origin ? null : origin;
    particles.setOrigin(selected);
    sankey.setHighlight(selected, hover?.type === 'link' ? hover.link : null);
    needsDraw = true;
  }

  wrap.addEventListener('pointermove', (e) => {
    const r = wrap.getBoundingClientRect();
    pointer = { x: e.clientX, y: e.clientY };
    setHover(sankey.hit(e.clientX - r.left, e.clientY - r.top));
  });
  wrap.addEventListener('pointerleave', () => setHover(null));
  wrap.addEventListener('click', (e) => {
    const r = wrap.getBoundingClientRect();
    const h = sankey.hit(e.clientX - r.left, e.clientY - r.top);
    if (h?.type === 'node' && h.node.column === 0) select(h.node.id);
    else if (!h && selected) select(selected);
  });
  sankey.nodeSel
    .on('focus', function (_, n) {
      const box = this.getBoundingClientRect();
      pointer = { x: box.right, y: box.top };
      setHover({ type: 'node', node: n });
    })
    .on('blur', () => setHover(null))
    .on('keydown', (e, n) => {
      if ((e.key === 'Enter' || e.key === ' ') && n.column === 0) {
        e.preventDefault();
        e.stopPropagation();
        select(n.id);
      }
    });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      setHover(null);
      if (selected) select(selected);
    }
  });

  // Layout.
  const priceEl = document.getElementById('price-chart');
  function resize() {
    const w = wrap.clientWidth;
    const narrow = w < 620;
    // Fill what is left of the first screen, within limits that keep labels readable.
    const room = window.innerHeight - (wrap.getBoundingClientRect().top + window.scrollY) - 16;
    const h = narrow ? 560 : Math.max(470, Math.min(760, room));
    wrap.style.height = `${h}px`;
    sankey.layout(w, h);
    particles.resize(w, h);
    chart.resize(priceEl.clientWidth);
    placeCard();
    lastDay = -1;
    applyCursor();
    needsDraw = true;
  }
  new ResizeObserver(resize).observe(wrap);
  window.addEventListener('resize', resize);
  resize();

  if (!reduceMotion) particles.warm(values);

  // Animation loop. Pausing stops everything, including particles.
  let last = performance.now();
  function tick(now) {
    const dt = Math.max(0, Math.min(0.1, (now - last) / 1000));
    last = now;
    let moved = false;
    if (playing && holdLeft > 0) {
      // Stopped at an event: the date holds while oil keeps moving.
      holdLeft -= dt;
      if (holdLeft <= 0) hideCard();
    } else if (playing) {
      cursor += (dt * 1000) / msPerDay;
      const ev = popups[nextPopup];
      if (ev && cursor >= ev.index) {
        cursor = ev.index;
        nextPopup += 1;
        holdLeft = HOLD_SECONDS[msPerDay];
        showCard(ev);
      }
      if (cursor >= frames.length - 1) {
        cursor = frames.length - 1;
        playing = false;
        ended = true;
        setState();
      }
      moved = true;
    } else if (jump) {
      jump.t = Math.min(1, jump.t + dt / 0.22);
      cursor = jump.from + (jump.to - jump.from) * d3.easeCubicOut(jump.t);
      if (jump.t >= 1) {
        cursor = jump.to;
        jump = null;
        applyCursor();
        syncCard();
      }
      moved = true;
    }
    if (moved) applyCursor();
    if (reduceMotion) {
      if (needsDraw) particles.clear();
    } else if (playing) {
      particles.step(dt, values);
      particles.draw();
    } else if (moved || needsDraw) {
      particles.draw();
    }
    needsDraw = false;
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);

  // Play on load, except for readers who asked for less motion.
  if (!reduceMotion) {
    playing = true;
  }
  setState();
}

main();
