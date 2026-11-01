import * as d3 from 'd3';

const el = document.getElementById('flow-tip');

export function showTooltip(html, clientX, clientY) {
  el.innerHTML = html;
  el.hidden = false;
  const r = el.getBoundingClientRect();
  const pad = 12;
  let x = clientX + pad;
  let y = clientY + pad;
  if (x + r.width > window.innerWidth - 8) x = Math.max(8, clientX - r.width - pad);
  if (y + r.height > window.innerHeight - 8) y = Math.max(8, clientY - r.height - pad);
  el.style.left = `${x}px`;
  el.style.top = `${y}px`;
}

export function hideTooltip() {
  el.hidden = true;
}

// Node history with today's position and the Jan-Feb baseline.
export function sparkline(series, baseline, day, warIndex) {
  const w = 220;
  const h = 40;
  const x = d3.scaleLinear().domain([0, series.length - 1]).range([1, w - 3]);
  const y = d3.scaleLinear().domain([0, d3.max(series) * 1.05 || 1]).range([h - 2, 2]);
  const d = d3.line().x((_, i) => x(i)).y((v) => y(v))(series);
  return `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" aria-hidden="true">
    <line x1="1" x2="${w - 3}" y1="${y(baseline)}" y2="${y(baseline)}" stroke="var(--axis)" />
    <line x1="${x(warIndex)}" x2="${x(warIndex)}" y1="2" y2="${h - 2}" stroke="var(--ink-2)" stroke-dasharray="3 3" />
    <path d="${d}" fill="none" stroke="var(--ink)" stroke-width="1.5" />
    <circle cx="${x(day)}" cy="${y(series[day])}" r="4" fill="var(--ink)" stroke="var(--surface)" stroke-width="2" />
  </svg>`;
}
