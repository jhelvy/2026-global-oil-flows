# Methodology and data gaps

Rerun everything with `Rscript run_all.R` from the repo root. API keys go in a git-ignored `.env`, as `COMTRADE_API_KEY`, `EIA_API_KEY` and `FRED_API_KEY`. Files that need a person with a browser go in `data/raw/manual/` (see `DOWNLOADS_NEEDED.md`). The front end lives in `web/`: run `npm install` and `npm run dev` there.

## Scope decisions

- **Crude plus lease condensate**, per the plan's recommendation. EIA International (product 57) is the production source because it has one definition and sums to a world total. JODI's crude definition varies by country, so JODI supplies only refinery intake, direct use, imports and exports.
- **Brent on the chart.** WTI is in `flows.json` but not drawn.
- **Other seaborne stays one route.** It is not split by Bab el-Mandeb, Suez and Cape.

## Method

1. **Consumption** is crude refinery runs plus direct burn. World crude use closes on IEA global refinery throughput (`data/raw/iea_refinery_runs.csv`). The stock term is runs minus production. Rest of World is the residual, steady at about 15 to 16 mb/d. STEO total-liquids stock change is kept only for comparison, because it is largely products.
2. **Trade.** The Energy Institute 2025 inter-area crude matrix is the seed. Comtrade splits its regions into the node groups and supplies intra-Europe flows that EI excludes. Iterative proportional fitting rescales the seed to each month's totals, converging in 21 to 27 iterations.
3. **Routes.** Gulf exports are production minus domestic use. Bypass pipelines fill first, up to dated capacities in `data/raw/route_assumptions.csv`. The rest crosses the strait.
4. **Hormuz volumes** come from `data/raw/hormuz_crude_targets.csv`. A shortfall against the month's figure becomes a release from storage, drawn as the blue stock band through the strait. An excess becomes stored oil. Either way, net stock change and consumer totals hold.
5. **Daily shape.** Each producer-route-consumer flow keeps its monthly mean exactly. Hormuz flows follow the 7-day tanker count plus a small constant, because one vessel must not double a flow when counts are near zero. Pre-war swings carry half weight, because a 60% late-February rise in vessel counts would overstate the starting point. Other flows interpolate between mid-month points, with a break at the war start.

## Confidence by month

| Months | Production | Global refinery runs | Hormuz crude |
|---|---|---|---|
| Jan to Feb | EIA | IEA reported | Tanker counts, factsheet baseline |
| Mar | EIA | IEA reported | IEA reported |
| Apr to Jun | EIA | IEA reported | Derived from IEA all-oil figures |
| Jul | STEO extension | IEA reported | Derived from IEA excerpts via a trade press summary |
| Aug | STEO extension | Interpolated | Derived from an IEA commentary |
| Sep | STEO extension | Interpolated | **Assumption:** 1.1 times August, from EIA's "increased slightly" |
| Oct | STEO extension | Forecast | **Assumption:** held at September |

The IEA reports for August to October need a paid subscription and were not used. `data/interim/gaps_consumption.csv` lists, by group and month, the share of consumption that countries actually reported. JODI runs through August and EIA International through June.

## Validation

`R/07_validate.R` stops the pipeline on a failed check and writes `qa/validation_results.csv` and `qa/calibration_comparison.csv`. The worst calibration gaps:

- Yanbu plus Fujairah comes in about 20% under IEA in February and June, as expected, because the model is crude only and IEA's figure is all oil.
- That same figure is 10% over IEA in August. With Saudi at 3.82 and UAE at 1.8 mb/d, the model's 5.62 mb/d sits between IEA's 5.5 for both ports and EIA's "more than 5.0" for Yanbu alone, so the sources themselves disagree.
- Middle East runs are 11% over IEA in April.
- China runs are 7% under the NBS-based figure in June.

## Known gaps and open items

- PortWatch returned no rows for Yanbu, Ras Tanura or Kharg, so the bypass ramp is not shaped by port data.
- Comtrade 2025 lacks some reporters, so the newest year per reporter is used.
- Flows have no voyage lag. Dips and spikes at consumers on the day of a Hormuz change are an artifact of that, most visibly Japan around March 1.
- Marine insurers' cancellation of Gulf war-risk cover took effect March 5, not March 1 as in the plan's timeline. Both dates are in `data/raw/events.csv`, each for what happened that day.
- The plan's timeline says about 6 vessels a day against about 100 pre-war. That counts all vessels. The model uses PortWatch tankers only, which averaged about 37 a day before the war, and fell to about 1.
- The plan describes the strait as effectively closed again in August. The IEA commentary of September 18 puts August flows at 7.6 mb/d of all oil, against about 20 before the war. The model follows the IEA figure, so August reads as heavily reduced and not as closed.
- The plan's "about 20% of world supply" is all oil. In crude terms the model's pre-war Hormuz flow is 14.7 mb/d, or 17.2% of crude supply, which matches IEA's 14.95 mb/d for 2025.
- Sources disagree on the October IEA report's date (October 10 and 14), so it is not a timeline event.
