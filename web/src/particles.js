// Canvas particles. Each link spawns dots at a rate proportional to its current mb/d, so
// a shrinking flow thins out on its own. Positions come from the same cubic curve that
// sankeyLinkHorizontal draws, with a random offset across the band.
const MAX_PARTICLES = 3500;
const LIFETIME = 2.4; // seconds to cross one link
const RATE = 4.2; // particles per mb/d per second

export function createParticles(canvas, data, geom) {
  const { links } = data;
  const ctx = canvas.getContext('2d');
  const linkIdx = new Int16Array(MAX_PARTICLES);
  const pos = new Float32Array(MAX_PARTICLES);
  const off = new Float32Array(MAX_PARTICLES);
  const acc = new Float32Array(links.length);
  let count = 0;
  let cursor = 0;
  let width = 0;
  let height = 0;
  let colors = [];
  let origin = null;

  function readColors() {
    const style = getComputedStyle(document.documentElement);
    colors = links.map((l) => style.getPropertyValue(`--${l.origin}`).trim());
  }

  function resize(w, h) {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    width = w;
    height = h;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function spawn(i) {
    linkIdx[cursor] = i;
    pos[cursor] = 0;
    off[cursor] = Math.random() - 0.5;
    cursor = (cursor + 1) % MAX_PARTICLES;
    if (count < MAX_PARTICLES) count++;
  }

  function step(dt, values) {
    for (let i = 0; i < links.length; i++) {
      acc[i] += RATE * values[i] * dt;
      while (acc[i] >= 1) {
        spawn(i);
        acc[i] -= 1;
      }
    }
    const adv = dt / LIFETIME;
    for (let p = 0; p < count; p++) pos[p] += adv;
  }

  // Fills the diagram immediately instead of starting empty.
  function warm(values) {
    for (let i = 0; i < 80; i++) step(0.04, values);
  }

  function draw() {
    ctx.clearRect(0, 0, width, height);
    const { x0, x1, y0, y1, w } = geom;
    for (let p = 0; p < count; p++) {
      const u = pos[p];
      if (u >= 1) continue;
      const i = linkIdx[p];
      if (w[i] < 0.02) continue;
      if (origin && links[i].origin !== origin) continue;
      const v = 1 - u;
      const dx = x1[i] - x0[i];
      const x = x0[i] + dx * (1.5 * u * v + u * u * u);
      const y = y0[i] + (y1[i] - y0[i]) * (3 * u * u - 2 * u * u * u) + off[p] * w[i] * 0.92;
      ctx.globalAlpha = Math.min(1, u * 12, v * 7);
      ctx.fillStyle = colors[i];
      ctx.fillRect(x - 1, y - 1, 2, 2);
    }
    ctx.globalAlpha = 1;
  }

  const clear = () => ctx.clearRect(0, 0, width, height);

  return { resize, step, warm, draw, clear, readColors, setOrigin: (o) => (origin = o) };
}
