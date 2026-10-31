// Fixed-scale Sankey. Every node owns a fixed vertical slot sized to its largest value
// across all dates, and one scale applies to every frame, so a shrinking flow reads as a
// smaller band instead of the diagram renormalizing. d3-sankey's generator refits its
// layout to the available height each call, so only its link path shape is used here.
import * as d3 from 'd3';
import { sankeyLinkHorizontal } from 'd3-sankey';

const NODE_W = 14;
const SHORT = {
  'Saudi Arabia': 'Saudi', 'Rest of World': 'ROW', 'Stock draws / SPR': 'Stocks', 'South Korea': 'Korea',
  'Europe (EU + UK)': 'Europe', 'Middle East': 'Mideast', 'Strait of Hormuz': 'Hormuz',
  'Gulf bypass pipelines': 'Bypass', 'Other seaborne': 'Seaborne', 'Cross-border pipelines': 'Pipelines',
  'Domestic (no transit)': 'Domestic', 'Stock builds': 'Stocks', 'Other Gulf': 'O. Gulf', 'Other Asia': 'O. Asia',
};

export function fmtPct(now, base) {
  if (base < 0.05) return '';
  const p = Math.round((100 * (now - base)) / base);
  return `${p > 0 ? '+' : p < 0 ? '−' : ''}${Math.abs(p)}%`;
}

export function createSankey(svgEl, data) {
  const { nodes, links } = data;
  const svg = d3.select(svgEl);
  const gLinks = svg.append('g').attr('class', 'links');
  const gNodes = svg.append('g').attr('class', 'nodes');
  const gHeads = svg.append('g');
  const linkPath = sankeyLinkHorizontal();

  const geom = {
    x0: new Float32Array(links.length),
    x1: new Float32Array(links.length),
    y0: new Float32Array(links.length),
    y1: new Float32Array(links.length),
    w: new Float32Array(links.length),
  };
  const shape = links.map(() => ({ source: { x1: 0 }, target: { x0: 0 }, y0: 0, y1: 0 }));
  const paths = gLinks
    .selectAll('path')
    .data(links)
    .join('path')
    .attr('stroke', (l) => `var(--${l.origin})`)
    .nodes();

  const nodeSel = gNodes
    .selectAll('g')
    .data(nodes)
    .join('g')
    .attr('class', (n) => `node ${n.column === 0 ? 'producer' : ''} ${n.id === 'r_hormuz' ? 'hormuz' : ''}`)
    .attr('tabindex', 0)
    .attr('role', 'group')
    .attr('aria-label', (n) => n.label);
  nodeSel.append('rect').attr('class', 'hit');
  nodeSel
    .append('rect')
    .attr('class', 'bar')
    .attr('fill', (n) => (n.column === 0 ? `var(--${n.id})` : 'var(--node)'));
  nodeSel.append('rect').attr('class', 'ghost');
  const labels = nodeSel.append('text').attr('dy', '0.35em');
  labels.append('tspan').attr('class', 'name');
  labels.append('tspan').attr('class', 'val').attr('dx', 5);
  labels.append('tspan').attr('class', 'pct').attr('dx', 4);

  const heads = gHeads
    .selectAll('text')
    .data([
      { column: 0, label: 'Producers' },
      { column: 1, label: 'Routes' },
      { column: 2, label: 'Consumers' },
    ])
    .join('text')
    .attr('class', 'col-head')
    .attr('y', 11);

  let k = 1;
  let narrow = false;
  const colX = [0, 0, 0];

  function layout(width, height) {
    narrow = width < 620;
    const gutter = narrow ? 92 : 178;
    colX[0] = gutter;
    colX[2] = width - gutter - NODE_W;
    colX[1] = (colX[0] + colX[2]) / 2 - NODE_W / 2 - (narrow ? 0 : 20);
    svg.attr('viewBox', `0 0 ${width} ${height}`);

    const top = 20;
    const avail = height - top;
    const minSlot = narrow ? 14 : 16;
    const pad = 4;

    // Largest scale at which every column fits, given a minimum slot for label room.
    const fits = (s, col) =>
      d3.sum(col, (n) => Math.max(n.max * s, minSlot)) + pad * (col.length - 1) <= avail;
    const cols = [0, 1, 2].map((c) => nodes.filter((n) => n.column === c));
    let lo = 0.1;
    let hi = avail;
    for (let i = 0; i < 40; i++) {
      const mid = (lo + hi) / 2;
      if (cols.every((col) => fits(mid, col))) lo = mid;
      else hi = mid;
    }
    k = lo;

    for (const col of cols) {
      const used = d3.sum(col, (n) => Math.max(n.max * k, minSlot));
      const gap = (avail - used) / Math.max(1, col.length - 1);
      let y = top;
      for (const n of col) {
        const slot = Math.max(n.max * k, minSlot);
        n.slotY = y;
        n.slotH = slot;
        n.cy = y + slot / 2;
        n.x = colX[n.column];
        y += slot + gap;
      }
    }

    nodeSel.select('rect.hit').attr('x', (n) => n.x - 2).attr('width', NODE_W + 4).attr('y', (n) => n.slotY).attr('height', (n) => n.slotH);
    nodeSel.select('rect.bar').attr('x', (n) => n.x).attr('width', NODE_W);
    nodeSel
      .select('rect.ghost')
      .attr('x', (n) => n.x - 1.5)
      .attr('width', NODE_W + 3)
      .attr('y', (n) => n.cy - (n.baseline * k) / 2)
      .attr('height', (n) => n.baseline * k);

    labels
      .attr('y', (n) => n.cy)
      .attr('x', (n) => (n.column === 0 ? n.x - 7 : n.x + NODE_W + 7))
      .attr('text-anchor', (n) => (n.column === 0 ? 'end' : 'start'));
    labels.select('.name').text((n) => (narrow ? SHORT[n.label] ?? n.label : n.label));
    labels.select('.pct').style('display', narrow ? 'none' : null);
    // Route labels sit over the links, so narrow screens keep names only there.
    labels.select('.val').style('display', (n) => (narrow && n.column === 1 ? 'none' : null));

    heads
      .attr('x', (d) => (d.column === 0 ? colX[0] + NODE_W : d.column === 1 ? colX[1] : colX[2]))
      .attr('text-anchor', (d) => (d.column === 0 ? 'end' : 'start'))
      .text((d) => d.label);

    for (const l of links) {
      const i = l.i;
      geom.x0[i] = l.sNode.x + NODE_W;
      geom.x1[i] = l.tNode.x;
      shape[i].source.x1 = geom.x0[i];
      shape[i].target.x0 = geom.x1[i];
    }
  }

  // Values are mb/d for each link, already interpolated between days.
  function update(values) {
    for (const n of nodes) {
      let total = 0;
      for (const i of n.valueLinks) total += values[i];
      n.now = total;
      const h = total * k;
      n.top = n.cy - h / 2;
      n.h = h;
      let y = n.top;
      for (const i of n.outOrder) {
        const w = values[i] * k;
        geom.y0[i] = y + w / 2;
        y += w;
      }
      y = n.top;
      for (const i of n.inOrder) {
        const w = values[i] * k;
        geom.y1[i] = y + w / 2;
        y += w;
      }
    }
    for (let i = 0; i < links.length; i++) {
      const w = values[i] * k;
      geom.w[i] = w;
      const s = shape[i];
      s.y0 = geom.y0[i];
      s.y1 = geom.y1[i];
      const el = paths[i];
      if (w < 0.02) {
        el.setAttribute('d', '');
      } else {
        el.setAttribute('d', linkPath(s));
        el.setAttribute('stroke-width', w.toFixed(2));
      }
    }
    nodeSel
      .select('rect.bar')
      .attr('y', (n) => n.top)
      .attr('height', (n) => Math.max(n.h, 0));
  }

  // Labels show the day's own value, not a position part way through a tween.
  function updateLabels(day) {
    labels.select('.val').text((n) => n.series[day].toFixed(1));
    labels.select('.pct').text((n) => fmtPct(n.series[day], n.baseline));
  }

  // Finds what sits under a point. All links in a gap share an x span, so the curve
  // parameter is solved once and the bands are tested directly, without per-path DOM events.
  function hit(mx, my) {
    for (const n of nodes) {
      if (mx >= n.x - 4 && mx <= n.x + NODE_W + 4 && my >= n.slotY && my <= n.slotY + n.slotH) {
        return { type: 'node', node: n };
      }
    }
    const gap = mx > colX[0] + NODE_W && mx < colX[1] ? 'left' : mx > colX[1] + NODE_W && mx < colX[2] ? 'right' : null;
    if (!gap) return null;
    const ax = gap === 'left' ? colX[0] + NODE_W : colX[1] + NODE_W;
    const bx = gap === 'left' ? colX[1] : colX[2];
    const tx = (mx - ax) / (bx - ax);
    let lo = 0;
    let hi = 1;
    for (let i = 0; i < 14; i++) {
      const u = (lo + hi) / 2;
      if (1.5 * u * (1 - u) + u * u * u < tx) lo = u;
      else hi = u;
    }
    const u = (lo + hi) / 2;
    const f = 3 * u * u - 2 * u * u * u;
    let best = null;
    let bestDist = Infinity;
    for (const l of links) {
      if (l.side !== gap || geom.w[l.i] < 0.02) continue;
      const y = geom.y0[l.i] + (geom.y1[l.i] - geom.y0[l.i]) * f;
      const half = geom.w[l.i] / 2;
      const d = Math.abs(my - y);
      if (d <= half + 3) {
        // Inside a band beats merely near one, and among overlaps the thinner band wins.
        const score = d <= half ? geom.w[l.i] - 1000 : d;
        if (score < bestDist) {
          bestDist = score;
          best = l;
        }
      }
    }
    return best ? { type: 'link', link: best } : null;
  }

  function setHighlight(selectedOrigin, hotLink) {
    d3.selectAll(paths)
      .classed('dim', (l) => selectedOrigin && l.origin !== selectedOrigin)
      .classed('hot', (l) => hotLink && l.i === hotLink.i);
    nodeSel.classed('dim', (n) => selectedOrigin && !n.touchedBy.has(selectedOrigin));
  }

  return { layout, update, updateLabels, hit, setHighlight, geom, nodeSel, getScale: () => k };
}
