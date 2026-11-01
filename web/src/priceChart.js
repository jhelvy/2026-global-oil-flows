// Brent line with a transit panel beneath it. Two panels, not two axes on one plot: their
// scales are unrelated, and aligning them would imply a relationship the data does not state.
import * as d3 from 'd3';

export function createPriceChart(root, data, { onSeek, onHover, onLeave }) {
  const { dates, frames, warIndex } = data;
  const svg = d3.select(root).append('svg');
  const defs = svg.append('defs');
  const clipId = 'played-clip';
  const clipRect = defs.append('clipPath').attr('id', clipId).append('rect');
  const margin = { top: 16, right: 14, bottom: 20, left: 34 };

  const gGridP = svg.append('g').attr('class', 'gridlines');
  const warLine = svg.append('line').attr('class', 'event-line');
  const gAxisY = svg.append('g').attr('class', 'axis');
  const gAxisT = svg.append('g').attr('class', 'axis');
  const gAxisX = svg.append('g').attr('class', 'axis');
  const pDim = svg.append('path').attr('class', 'series-dim');
  const pFull = svg.append('path').attr('class', 'series').attr('clip-path', `url(#${clipId})`);
  const tDim = svg.append('path').attr('class', 'series-dim');
  const tFull = svg.append('path').attr('class', 'series tankers').attr('clip-path', `url(#${clipId})`);
  const playhead = svg.append('line').attr('class', 'playhead');
  // Text goes after the lines, so its halo keeps the playhead from striking through it.
  const titleP = svg.append('text').attr('class', 'panel-title').text('Brent spot, $ per barrel');
  const titleT = svg.append('text').attr('class', 'panel-title').text('Hormuz tankers per day, 7-day average');
  const warLabel = svg.append('text').attr('class', 'event-label').text('War starts Feb 28');
  const tagP = svg.append('text').attr('class', 'play-tag');
  const tagT = svg.append('text').attr('class', 'play-tag');

  let x = d3.scaleTime();
  let yP = d3.scaleLinear();
  let yT = d3.scaleLinear();
  let width = 0;

  function resize(w) {
    width = w;
    const narrow = w < 620;
    const hP = 76;
    const hT = 48;
    const gap = 24;
    const height = margin.top + hP + gap + hT + margin.bottom;
    svg.attr('viewBox', `0 0 ${w} ${height}`).attr('height', height);
    const innerL = margin.left;
    const innerR = w - margin.right;
    x = d3.scaleUtc().domain([dates[0], dates[dates.length - 1]]).range([innerL, innerR]);

    const pTop = margin.top;
    const pBot = pTop + hP;
    const tTop = pBot + gap;
    const tBot = tTop + hT;
    yP = d3.scaleLinear().domain(d3.extent(frames, (f) => f.brent)).nice().range([pBot, pTop]);
    yT = d3.scaleLinear().domain([0, d3.max(frames, (f) => f.hormuz_tankers_7d)]).nice().range([tBot, tTop]);

    const lineP = d3.line().x((f) => x(f.dateObj)).y((f) => yP(f.brent));
    const lineT = d3.line().x((f) => x(f.dateObj)).y((f) => yT(f.hormuz_tankers_7d));
    pDim.attr('d', lineP(frames));
    pFull.attr('d', lineP(frames));
    tDim.attr('d', lineT(frames));
    tFull.attr('d', lineT(frames));
    clipRect.attr('x', 0).attr('y', 0).attr('height', height);

    gGridP
      .selectAll('line')
      .data(yP.ticks(4))
      .join('line')
      .attr('x1', innerL)
      .attr('x2', innerR)
      .attr('y1', (d) => yP(d))
      .attr('y2', (d) => yP(d));
    gAxisY.attr('transform', `translate(${innerL},0)`).call(d3.axisLeft(yP).ticks(4).tickSize(0).tickPadding(6)).call((g) => g.select('.domain').remove());
    gAxisT.attr('transform', `translate(${innerL},0)`).call(d3.axisLeft(yT).ticks(2).tickSize(0).tickPadding(6)).call((g) => g.select('.domain').remove());
    gAxisX
      .attr('transform', `translate(0,${tBot})`)
      .call(d3.axisBottom(x).ticks(d3.utcMonth.every(narrow ? 2 : 1)).tickFormat(d3.utcFormat('%b')).tickSizeOuter(0).tickSize(4));

    const warX = x(dates[warIndex]);
    warLine.attr('x1', warX).attr('x2', warX).attr('y1', pTop).attr('y2', tBot);

    titleP.attr('x', innerL).attr('y', pTop - 5);
    titleT.attr('x', innerL).attr('y', tTop - 5);
    warLabel.attr('x', x(dates[warIndex]) + 5).attr('y', pBot - 4).style('display', narrow ? 'none' : null);
    playhead.attr('y1', pTop).attr('y2', tBot);
  }

  function setCursor(f) {
    const i0 = Math.floor(f);
    const i1 = Math.min(i0 + 1, frames.length - 1);
    const a = f - i0;
    const px = x(new Date(+dates[i0] + a * (+dates[i1] - +dates[i0])));
    clipRect.attr('width', px);
    playhead.attr('x1', px).attr('x2', px);
    const fr = frames[Math.round(f)];
    const right = px > width - margin.right - 40;
    // Tags flip under the line near a panel's top, so they stay clear of its title.
    const tagY = (y, top) => (y - top < 16 ? y + 15 : y - 6);
    tagP
      .attr('x', right ? px - 6 : px + 6)
      .attr('text-anchor', right ? 'end' : 'start')
      .attr('y', tagY(yP(fr.brent), yP.range()[1]))
      .text(`$${fr.brent.toFixed(0)}`);
    tagT
      .attr('x', right ? px - 6 : px + 6)
      .attr('text-anchor', right ? 'end' : 'start')
      .attr('y', tagY(yT(fr.hormuz_tankers_7d), yT.range()[1]))
      .text(fr.hormuz_tankers_7d.toFixed(0));
  }

  function indexAt(event) {
    const [mx] = d3.pointer(event, svg.node());
    const d = x.invert(mx);
    return Math.max(0, Math.min(dates.length - 1, d3.bisectCenter(dates, d)));
  }

  let dragging = false;
  svg
    .on('pointerdown', (event) => {
      dragging = true;
      onSeek(indexAt(event));
    })
    .on('pointermove', (event) => {
      const i = indexAt(event);
      if (dragging) onSeek(i);
      onHover(i, event);
    })
    .on('pointerup pointercancel', () => (dragging = false))
    .on('pointerleave', () => {
      dragging = false;
      onLeave();
    });

  return { resize, setCursor };
}
