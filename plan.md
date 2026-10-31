# Global Oil Flows 2026 — Animated Sankey: Project Plan

## 1. Goal

Build an interactive, animated web graphic that shows how oil moves around the world day by day through 2026. It focuses on the shock caused by the US/Israel–Iran war and the closure of the Strait of Hormuz.

- **Left side:** oil supply by producer (USA, Gulf states, Russia, etc., with smaller ones grouped as "Rest of World").
- **Middle:** the *route* the oil takes (Strait of Hormuz, Gulf bypass pipelines, other seaborne, cross-border pipelines, domestic use).
- **Right side:** oil consumption by country or region.
- **Above the Sankey:** a line chart of the daily Brent price, with a playhead synced to the animation.
- **Animation:** particles flow left → middle → right. As time advances, link widths change and the Hormuz band visibly pinches shut after Feb 28, 2026 while the price line spikes.

Two stages:

1. **R** fetches, cleans, models, and exports all the data.
2. **JavaScript (D3)** renders the interactive graphic from the exported JSON.

---

## 2. Story Timeline (verify and extend during data work)

| Date | Event |
|---|---|
| Jan 1 – Feb 27, 2026 | Normal baseline flows |
| Feb 17, 2026 | IRGC briefly closes parts of Hormuz for live-fire drills (a few hours) |
| **Feb 28, 2026** | US-Israeli strikes on Iran; IRGC announces closure of the Strait of Hormuz |
| Mar 1, 2026 | Major shipping lines suspend Gulf operations; war-risk insurance cancelled |
| Mar 2026 onward | Hormuz transits fall about 95% (about 6 vessels/day vs. a pre-war average of about 100) |
| Jun–Jul 2026 | Partial resumption of transits (still well below normal) |
| Aug 2026 | Strait reported effectively closed again; IEA cuts its demand forecast |
| → Present (end of Oct 2026) | Fill in from the data |

**Agent task:** build `data/raw/events.csv` (date, label, source_url) from reputable news and IEA/EIA reports. Use it for chart annotations. Every event needs a source URL.

---

## 3. Data Sources

### 3.1 Daily oil price (line chart)
- **Brent spot, daily (USD/bbl):** FRED series `DCOILBRENTEU`, sourced from the EIA.
  - https://fred.stlouisfed.org/series/DCOILBRENTEU
  - R: `fredr::fredr(series_id = "DCOILBRENTEU", observation_start = as.Date("2025-12-01"))` (free FRED API key), or read the CSV download directly.
  - Optional second line: WTI (`DCOILWTICO`).
- **Notes:** business days only. Forward-fill weekends and holidays for the animation, but flag those values as `imputed` in the export. The EIA publishes with about a 1-business-day lag. FRED can lag the EIA by a few days, so if the latest week is missing, try the EIA API (series `PET.RBRTE.D`).

### 3.2 Daily Hormuz signal (the core of the shock)
- **IMF PortWatch: Daily Chokepoint Transit Calls and Trade Volume Estimates.**
  - https://portwatch.imf.org
  - Hormuz = `portid == "chokepoint6"`. Fields include `n_total`, `n_tanker`, `n_cargo`, and estimated trade volume (capacity) columns.
  - Built from satellite AIS data. Counts transits in both directions and does not split inbound from outbound.
  - Access: the public ArcGIS feature service (`Daily_Chokepoints_Data`) behind the PortWatch data download page. Query it via the ArcGIS REST API with `httr2`, or use the CSV export.
  - **Fallback mirror:** https://straits.live/data (daily CSV of date, total, tanker, cargo) and the GitHub mirror `github.com/jasonhjohnson/strait-of-hormuz-data`. Cite IMF PortWatch when republishing.
- **Also pull for context (same dataset):** Bab el-Mandeb, Suez Canal, Cape of Good Hope. These are useful if we later split "other seaborne" by route.
- **Also check PortWatch's port-level data** for Gulf export ports (Ras Tanura, Basra, Fujairah, Yanbu). Yanbu and Fujairah activity is a direct signal for the bypass pipelines.

### 3.3 Monthly production and consumption by country
- **JODI Oil World Database** (primary): monthly crude production, refinery intake, demand, and exports by country.
  - https://www.jodidata.org/oil/
  - Has a bulk CSV download. Expect a reporting lag of about 2 months, and some countries (notably Iran) are patchy.
- **EIA Open Data API v2** (cross-check, and to fill gaps):
  - https://www.eia.gov/opendata/
  - International data (`international` route) for country production and consumption.
  - **STEO** (`steo` route) for monthly world supply and demand estimates and forecasts, including OPEC production by country.
- **IEA Oil Market Report** (monthly; headline figures are public in press releases): use as **calibration targets** for global supply loss, demand changes, and stock draws.
  - https://www.iea.org/topics/oil-market-report
  - Example target: the IEA estimated total supply losses tied to the Hormuz closure at about 12.8 mb/d (a figure cited in a mid-2026 report). Record each IEA headline figure with its report month and URL in `data/raw/calibration_targets.csv`.

### 3.4 Who sells to whom (baseline trade matrix)
- **Energy Institute Statistical Review of World Energy:** annual inter-regional crude oil trade movements (from region → to region).
  - https://www.energyinst.org/statistical-review
  - Use the most recent year available as the **pre-war baseline share matrix**.
- **Optional refinement:** UN Comtrade (HS 2709, crude petroleum) monthly bilateral trade, which gives country-level detail where available. Comtrade lags several months, so it is only useful for early 2026.

### 3.5 Route attribution (middle column)
Hard-code a documented assumptions table, `data/raw/route_assumptions.csv`, with the share of each producer's exports by route. Sources: EIA "World Oil Transit Chokepoints" and country analysis briefs.
- Hormuz exporters: Saudi Arabia (east-coast terminals), Iraq (Basra), Kuwait, UAE (except Fujairah), Qatar, Iran, Bahrain.
- **Gulf bypass pipelines (capacity-capped):**
  - Saudi East-West pipeline (Petroline) → Yanbu (Red Sea)
  - UAE Habshan–Fujairah pipeline (ADCOP) → Gulf of Oman
  - Iraq's Kirkuk–Ceyhan route, if operating
  - The agent should look up nameplate capacities from EIA and company sources and cite them. These caps limit how much Gulf oil can avoid Hormuz.
- Cross-border pipelines: Russia (Druzhba, ESPO, CPC via Kazakhstan), Canada → US.
- Domestic: production consumed in the same country (USA, China, Russia, Saudi domestic burn, etc.).

---

## 4. Node Design

Keep each column to roughly 8–11 nodes so the Sankey stays readable.

**Producers (left):**
USA · Saudi Arabia · Iraq · UAE · Kuwait · Iran · Other Gulf (Qatar, Bahrain, Oman) · Russia · Canada · Brazil · Rest of World (ROW) · **Stock draws / SPR releases** (balancing node)

**Routes (middle):**
Strait of Hormuz · Gulf bypass pipelines · Other seaborne · Cross-border pipelines · Domestic (no transit)

**Consumers (right):**
USA · China · India · Japan · South Korea · Europe (EU + UK) · Middle East (domestic) · Other Asia · Rest of World (ROW) · **Stock builds** (balancing node)

**Balancing logic:** production + stock draws = consumption + stock builds, for every day. When the Gulf is cut off, the "Stock draws / SPR releases" node grows, which is itself part of the story.

**Optional overlay:** a dashed "ghost" outline on each consumer node showing its Jan–Feb baseline. The gap between the ghost and the current bar shows demand lost against normal.

Units throughout: **million barrels per day (mb/d)**, crude plus condensate (decide whether to include NGLs and products; crude-only is cleaner and easier to source).

---

## 5. Modeling Method (R)

### Step 1 — Monthly country totals
- For each producer group: monthly production minus domestic use gives exports. Use JODI first and the EIA where JODI is missing.
- For each consumer group: monthly consumption, imports, and domestic supply.
- Reconcile the global totals against IEA/EIA world supply and demand for each month. Close any remaining gap with the stock change.

### Step 2 — Monthly producer → consumer matrix
1. Start from the baseline share matrix (Energy Institute annual trade, mapped to our groups).
2. For each month, rescale the matrix so that row sums equal each producer's exports and column sums equal each consumer's imports. Use **iterative proportional fitting (IPF / RAS)**; the `mipfp` package works, or write a simple loop.
3. Add the domestic flows (producer X → consumer X via "Domestic").

### Step 3 — Split by route
- Apply `route_assumptions.csv` shares to each producer → consumer flow.
- For Gulf producers after Feb 28: Hormuz flow is driven by the daily signal (Step 4). Bypass pipelines absorb volume up to their capacity cap. The remainder is shut in, and production falls.

### Step 4 — Daily resolution
- **Non-Gulf flows:** interpolate monthly values to daily. Use a **mean-preserving** spline (or linear interpolation between mid-month points, then rescaled) so that each month's daily average still equals the monthly figure.
- **Hormuz flows:** `hormuz_flow[d] = hormuz_baseline × (tanker_7day_avg[d] / tanker_baseline)`, where the baseline is the Jan 1 – Feb 27 average.
  - Use **tanker** transits (`n_tanker`), not total, and a 7-day trailing mean to smooth AIS noise.
  - If PortWatch's trade-volume estimate for tankers is usable, prefer it over counts (it's closer to barrels).
  - Then rescale within each month so that the monthly Hormuz total matches IEA/EIA estimates of Gulf exports, where available.
- **Bypass pipelines:** ramp up from about Mar 1 to the capacity cap. Shape the ramp with Yanbu/Fujairah port activity if available.
- **Stock draws:** daily value = consumption − production − (stock builds), smoothed.

### Step 5 — Validation (must pass before front-end work)
- Every day: total left = total right = total through the middle, to within 0.01 mb/d.
- Monthly means of the daily series match the monthly inputs to within 1%.
- Pre-war Hormuz flow is roughly in line with the commonly cited ~20% of global oil supply.
- The size of the supply drop in Mar–Apr is plausible against IEA/EIA reported losses.
- Spot-check charts: one PNG per producer and per route over time, saved to `qa/`.
- No negative flows.

### Step 6 — Export
One `flows.json` file (keep it under about 2 MB; round values to 3 decimals):

```json
{
  "meta": {
    "units": "mb/d",
    "generated": "2026-11-01",
    "start": "2026-01-01",
    "end": "2026-10-30",
    "sources": [{ "name": "IMF PortWatch", "url": "..." }],
    "notes": "Daily flows are modeled estimates; see methodology."
  },
  "nodes": [
    { "id": "p_saudi", "label": "Saudi Arabia", "column": 0, "group": "gulf" },
    { "id": "r_hormuz", "label": "Strait of Hormuz", "column": 1 },
    { "id": "c_china", "label": "China", "column": 2 }
  ],
  "links": [
    { "id": "p_saudi>r_hormuz", "source": "p_saudi", "target": "r_hormuz" }
  ],
  "frames": [
    {
      "date": "2026-01-01",
      "values": [9.1, 3.2],
      "brent": 72.40,
      "brent_imputed": false,
      "hormuz_tankers_7d": 41.3
    }
  ],
  "baseline": { "values": [9.1, 3.2] },
  "events": [{ "date": "2026-02-28", "label": "Strait of Hormuz closed", "url": "..." }]
}
```

- `frames[i].values` is a flat array aligned to `links`. This keeps the file small and makes tweening easy.
- `baseline` = Jan 1 – Feb 27 average, for ghost outlines and "% vs. normal" tooltips.
- Also write `flows_monthly.csv` and `flows_daily.csv` (long format: date, source, route, target, value) for inspection.

---

## 6. R Project Structure

```
oil-flows/
├── R/
│   ├── 01_fetch_prices.R        # FRED Brent (+ WTI)
│   ├── 02_fetch_portwatch.R     # Hormuz + other chokepoints, Gulf ports
│   ├── 03_fetch_jodi_eia.R      # monthly production/consumption
│   ├── 04_build_trade_matrix.R  # Energy Institute baseline + IPF
│   ├── 05_routes.R              # route split, bypass caps
│   ├── 06_daily_model.R         # interpolation + Hormuz daily driver
│   ├── 07_validate.R            # checks + QA plots
│   └── 08_export_json.R         # flows.json
├── data/
│   ├── raw/          # untouched downloads (cached; never edited by hand)
│   │   ├── events.csv
│   │   ├── route_assumptions.csv
│   │   └── calibration_targets.csv
│   ├── interim/
│   └── final/flows.json
├── qa/               # validation plots
├── _targets.R        # optional: {targets} pipeline tying 01–08 together
└── renv.lock
```

**Packages:** `tidyverse`, `httr2`, `jsonlite`, `fredr`, `readxl`, `lubridate`, `zoo` (rolling means), `mipfp` (or hand-rolled IPF), `targets`, `renv`.

**Conventions:**
- Cache every raw download to `data/raw/` with the download date in the filename, so reruns don't depend on live endpoints.
- API keys (FRED, EIA) go in `.Renviron`, never committed.
- Each script is runnable on its own and writes to `data/interim/`.

---

## 7. Front End (JavaScript / D3)

### Stack
- **Vite** (dev server + build) with vanilla JS. No framework is needed.
- **D3 v7** + **d3-sankey**.
- A **canvas** layer for particles; **SVG** for nodes, links, axes, and labels.

### Layout
```
┌─────────────────────────────────────────────┐
│  Title · date readout · play/pause · speed  │
├─────────────────────────────────────────────┤
│  Brent price line chart (~25% height)       │
│  └ moving playhead + event markers          │
├─────────────────────────────────────────────┤
│  Sankey: Producers → Routes → Consumers     │
│  (SVG links/nodes + canvas particles)       │
├─────────────────────────────────────────────┤
│  Date scrubber (full width)                 │
│  Source + "modeled estimates" footnote      │
└─────────────────────────────────────────────┘
```

### Sankey rendering
- **Fixed node order:** set `nodeSort` and `linkSort` explicitly (or to `null` with a fixed input order) so nodes never jump position between frames.
- Per frame: feed that frame's link values into the sankey generator, compute the layout, then **tween** node heights and link widths from the previous frame (about 150–300 ms ease) instead of snapping.
- **Fixed vertical scale:** compute the scale from the *maximum* total across all frames so that shrinking supply is visible as a smaller diagram, rather than being re-normalized to fill the space. This matters: without it, the Hormuz collapse won't look like a collapse.
- Color links by **producer** (Gulf producers in one warm hue family, Russia, Americas, etc.). Highlight the Hormuz route node.
- Node labels show the current mb/d and the % change vs. baseline.

### Particles
- Canvas overlay, same coordinates as the SVG.
- For each link, spawn particles at a rate proportional to its current value (e.g., 1 particle per X mb/d per second).
- Each particle travels along its link's path. Compute positions from the link's cubic Bézier (d3-sankey's horizontal link shape) using a random vertical offset within the link width, so particles fill the band.
- Particles take the color of their link and fade near the end.
- Cap the total particle count (~2–4k) for performance; use `requestAnimationFrame`.
- When Hormuz shuts, its particles thin out to a trickle. That is the key visual moment.

### Price chart
- D3 line of daily Brent across the full date range, drawn in full but dimmed. The portion up to the current date is drawn at full strength as it plays.
- Vertical playhead synced to the current frame.
- Event markers from `events` (e.g., a vertical dashed line at Feb 28 with a label).
- Optional secondary line: Hormuz tanker transits (7-day average), on a separate axis or in a small panel.

### Interaction
- Play/pause; speed control (e.g., 1 day = 50 / 100 / 200 ms).
- Scrubber to jump to any date; keyboard arrow keys step one day.
- Hover a link: source → route → target, mb/d today, mb/d baseline, % change.
- Hover a node: totals plus a small sparkline of that node over time.
- Click a producer: highlight its flows and dim the others.
- Responsive: the layout reflows on resize. On narrow screens, stack the price chart above and reduce the label density.

### Front-end structure
```
web/
├── index.html
├── src/
│   ├── main.js        # load flows.json, init, animation loop
│   ├── sankey.js      # layout, tweening, SVG render
│   ├── particles.js   # canvas particle system
│   ├── priceChart.js  # line chart + playhead
│   ├── controls.js    # play/pause, speed, scrubber, keyboard
│   └── tooltip.js
├── public/data/flows.json   # copied from R output
└── styles.css
```

---

## 8. Milestones

| # | Milestone | Done when |
|---|---|---|
| 1 | Price + PortWatch fetch | Daily Brent and Hormuz tanker series for Jan 1 → latest, cached, with a QA plot |
| 2 | Monthly country data | JODI/EIA monthly production and consumption for all node groups; gaps documented |
| 3 | Trade matrix + routes | Monthly producer → route → consumer flows balance; IPF converges |
| 4 | Daily model | Daily flows pass all validation checks in §5 Step 5 |
| 5 | JSON export | `flows.json` matches the schema; under 2 MB |
| 6 | Static Sankey | Renders any single date correctly from the JSON |
| 7 | Animation | Smooth tweened playback across all dates with a fixed scale |
| 8 | Particles | Particle flow proportional to volume; Hormuz visibly thins after Feb 28 |
| 9 | Price chart + sync | Playhead and event markers synced with the Sankey |
| 10 | Interaction + polish | Tooltips, scrubber, responsive layout, source footnote, methodology note |

Recommended order: do milestones 1 and 6 early, using placeholder flow values, so the visual can be prototyped while the full data model is still being built.

---

## 9. Known Limitations (state these on the graphic)

- **No public daily country-level production or consumption data exists.** Daily flows are *modeled*: monthly official data, shaped by daily shipping signals. True daily trade flows require paid tanker tracking (Kpler, Vortexa).
- PortWatch counts vessels, not barrels, and does not separate inbound from outbound. Tanker counts are a proxy for volume.
- JODI lags about 2 months, so the most recent months rely more on EIA STEO and IEA estimates (partly forecasts).
- Iranian export data is opaque; treat Iran as an estimate with wide uncertainty.
- The trade matrix shares are based on a pre-war annual baseline and rescaled; actual rerouting (e.g., Asian buyers shifting to US/Atlantic Basin crude) is only approximated. If time allows, adjust the shares using the Comtrade monthly data or news-reported rerouting.

---

## 10. Open Decisions

1. Crude-only vs. crude + condensate + NGLs vs. total liquids. Recommendation: crude + condensate.
2. Brent only, or Brent + WTI on the price chart.
3. Whether to split "Other seaborne" into sub-routes (Bab el-Mandeb / Suez / Cape) using PortWatch's other chokepoints.
4. Whether to add LNG as a toggle later (Hormuz also carries about 20% of global LNG).
5. Hosting: a static build (Vite) can deploy to GitHub Pages or Netlify.

---

## 11. Instructions for the Coding Agent

- Work milestone by milestone; don't start the front end's animation until the validation checks in §5 Step 5 pass.
- Never invent data values. If a source is unavailable, stop and report it, or use a documented assumption recorded in `data/raw/*.csv` with a source URL.
- Cite every external figure (capacities, calibration targets, events) with a URL in the relevant CSV.
- Keep raw downloads cached and reproducible; the whole R pipeline should rerun with one command (`targets::tar_make()` or `Rscript run_all.R`).
- Commit after each milestone with a short note on what was validated.
