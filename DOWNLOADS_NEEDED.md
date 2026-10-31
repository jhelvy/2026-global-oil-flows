# Files to download by hand

These sites block automated requests, so these files need a person with a browser. Save each one into `data/raw/manual/` using the filename shown. The pipeline picks them up automatically.

## 1. Energy Institute Statistical Review (plan section 3.4)

Domain: `energyinst.org`

Page: https://www.energyinst.org/statistical-review/resources-and-data-downloads

Download the newest full data workbook, titled something like "Statistical Review of World Energy Data" (`.xlsx`). It must include the oil "trade movements" tabs.

Save as: `data/raw/manual/ei_stats_review.xlsx`

## 2. IEA Oil Market Reports (plan section 3.3)

Domain: `iea.org`

Print each page to PDF. The public highlights are enough. Free IEA account access to the full report is even better, if you have it.

| Page | Save as |
|---|---|
| https://www.iea.org/reports/oil-market-report-march-2026 | `data/raw/manual/iea_omr_2026-03.pdf` |
| https://www.iea.org/reports/oil-market-report-april-2026 | `data/raw/manual/iea_omr_2026-04.pdf` |
| https://www.iea.org/reports/oil-market-report-may-2026 | `data/raw/manual/iea_omr_2026-05.pdf` |
| https://www.iea.org/reports/oil-market-report-june-2026 | `data/raw/manual/iea_omr_2026-06.pdf` |
| https://www.iea.org/reports/oil-market-report-july-2026 | `data/raw/manual/iea_omr_2026-07.pdf` |
| https://www.iea.org/reports/oil-market-report-august-2026 | `data/raw/manual/iea_omr_2026-08.pdf` |
| https://www.iea.org/reports/oil-market-report-september-2026 | `data/raw/manual/iea_omr_2026-09.pdf` |
| https://www.iea.org/reports/oil-market-report-october-2026 | `data/raw/manual/iea_omr_2026-10.pdf` |
| https://www.iea.org/topics/the-middle-east-and-global-energy-markets | `data/raw/manual/iea_middle_east_topic.pdf` |
| https://www.iea.org/commentaries/oil-markets-strain-to-plug-the-gap-left-by-middle-east-supply-shortfall | `data/raw/manual/iea_commentary_supply_shortfall.pdf` |

Status on 2026-10-31: everything above is in place except the August, September and October reports, which need a paid IEA subscription. Those months use public excerpts and EIA data, flagged as lower confidence in `METHODOLOGY.md`. If you get access, save them under the names above and update `data/raw/iea_refinery_runs.csv` and `data/raw/hormuz_crude_targets.csv`.

The figures I most need are monthly Hormuz flows, Gulf exports, supply losses, and crude versus product stock draws.
