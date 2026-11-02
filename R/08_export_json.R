# Write flows.json for the front end, plus long-format CSVs for inspection.
source(file.path("R", "00_setup.R"))

daily <- read_csv(file.path(path_interim, "flows_daily_model.csv"))
monthly <- read_csv(file.path(path_interim, "flows_monthly_model.csv"))
prices <- read_csv(file.path(path_interim, "prices_daily.csv"))
hormuz <- read_csv(file.path(path_interim, "hormuz_daily.csv"))
events <- read_csv(file.path(path_raw, "events.csv"))
hormuz_targets <- read_csv(file.path(path_raw, "hormuz_crude_targets.csv"))
iea_runs <- read_csv(file.path(path_raw, "iea_refinery_runs.csv"))

# Row order sets the top-to-bottom order of each column. This order came from a search over
# the non-Gulf producers, routes and consumer regions for the fewest band crossings and the
# least vertical travel, so same-country paths such as USA to USA run nearly straight.
nodes <- tribble(
  ~key, ~id, ~label, ~column, ~group,
  "saudi", "p_saudi", "Saudi Arabia", 0, "gulf",
  "iraq", "p_iraq", "Iraq", 0, "gulf",
  "uae", "p_uae", "UAE", 0, "gulf",
  "kuwait", "p_kuwait", "Kuwait", 0, "gulf",
  "iran", "p_iran", "Iran", 0, "gulf",
  "othergulf", "p_othergulf", "Other Gulf", 0, "gulf",
  "row", "p_row", "Rest of World", 0, "other",
  "brazil", "p_brazil", "Brazil", 0, "americas",
  "russia", "p_russia", "Russia", 0, "russia",
  "usa", "p_usa", "USA", 0, "americas",
  "canada", "p_canada", "Canada", 0, "americas",
  "stock", "p_stock", "Stocks, oil on water", 0, "stock",
  "hormuz", "r_hormuz", "Strait of Hormuz", 1, "hormuz",
  "bypass", "r_bypass", "Gulf bypass pipelines", 1, "route",
  "seaborne", "r_seaborne", "Other seaborne", 1, "route",
  "domestic", "r_domestic", "Domestic (no transit)", 1, "route",
  "pipeline", "r_pipeline", "Cross-border pipelines", 1, "route",
  "china", "c_china", "China", 2, "consumer",
  "india", "c_india", "India", 2, "consumer",
  "japan", "c_japan", "Japan", 2, "consumer",
  "korea", "c_korea", "South Korea", 2, "consumer",
  "otherasia", "c_otherasia", "Other Asia", 2, "consumer",
  "europe", "c_europe", "Europe (EU + UK)", 2, "consumer",
  "mideast", "c_mideast", "Middle East", 2, "consumer",
  "row", "c_row", "Rest of World", 2, "consumer",
  "usa", "c_usa", "USA", 2, "consumer",
  "stock", "c_stock", "Stock builds, oil on water", 2, "stock"
)

id_for <- function(key, col) {
  n <- nodes |> filter(column == col)
  n$id[match(key, n$key)]
}

flows <- daily |>
  mutate(
    p = id_for(producer, 0),
    r = id_for(route, 1),
    c = id_for(consumer, 2),
    p_i = match(p, nodes$id),
    r_i = match(r, nodes$id),
    c_i = match(c, nodes$id),
    # Rounding here keeps the left half an exact sum of the right half.
    mbd = round(mbd, 3)
  )
stopifnot(!anyNA(flows$p), !anyNA(flows$r), !anyNA(flows$c))

right_links <- flows |>
  distinct(p, r, c, p_i, r_i, c_i) |>
  arrange(r_i, p_i, c_i) |>
  transmute(
    id = paste0(p, "|", r, ">", c), source = r, target = c, origin = p, p, r, c
  )
left_links <- flows |>
  distinct(p, r, p_i, r_i) |>
  arrange(p_i, r_i) |>
  transmute(id = paste0(p, ">", r), source = p, target = r, origin = p, p, r, c = NA_character_)

links <- bind_rows(left_links, right_links)

right_wide <- flows |>
  mutate(id = paste0(p, "|", r, ">", c)) |>
  select(date, id, mbd)
left_wide <- flows |>
  group_by(date, id = paste0(p, ">", r)) |>
  summarise(mbd = round(sum(mbd), 3), .groups = "drop")

dates <- sort(unique(daily$date))
values <- bind_rows(left_wide, right_wide) |>
  mutate(link_i = match(id, links$id)) |>
  arrange(date, link_i)

value_matrix <- matrix(values$mbd, nrow = nrow(links), ncol = length(dates))
stopifnot(all(values$id[seq_len(nrow(links))] == links$id))

frame_data <- tibble(date = dates) |>
  left_join(prices |> select(date, brent, brent_imputed, wti, wti_imputed), by = "date") |>
  left_join(hormuz |> select(date, tanker_7d), by = "date")

frames <- map(seq_along(dates), \(i) {
  list(
    date = format(dates[i]),
    values = value_matrix[, i],
    brent = round(frame_data$brent[i], 2),
    brent_imputed = frame_data$brent_imputed[i],
    wti = round(frame_data$wti[i], 2),
    wti_imputed = frame_data$wti_imputed[i],
    hormuz_tankers_7d = round(frame_data$tanker_7d[i], 1)
  )
})

baseline_days <- dates <= date_baseline_end
baseline_values <- round(rowMeans(value_matrix[, baseline_days, drop = FALSE]), 3)

export <- list(
  meta = list(
    units = "mb/d",
    scope = "Crude oil including lease condensate",
    generated = format(Sys.Date()),
    start = format(min(dates)),
    end = format(max(dates)),
    war_start = format(date_war),
    sources = list(
      list(name = "IMF PortWatch (daily tanker transits)", url = "https://portwatch.imf.org"),
      list(name = "FRED / EIA (Brent and WTI spot)", url = "https://fred.stlouisfed.org/series/DCOILBRENTEU"),
      list(name = "EIA International (crude production)", url = "https://www.eia.gov/opendata/"),
      list(name = "EIA Short-Term Energy Outlook, October 2026", url = "https://www.eia.gov/outlooks/steo/"),
      list(name = "JODI Oil World Database (refinery intake, trade)", url = "https://www.jodidata.org/oil/"),
      list(name = "IEA Oil Market Report (refinery runs, Hormuz flows)", url = "https://www.iea.org/topics/oil-market-report"),
      list(name = "IEA Strait of Hormuz Factsheet", url = "https://www.iea.org/topics/the-middle-east-and-global-energy-markets"),
      list(name = "Energy Institute Statistical Review 2026 (trade baseline)", url = "https://www.energyinst.org/statistical-review"),
      list(name = "UN Comtrade HS 2709 (splits EI regions)", url = "https://comtradeplus.un.org/"),
      list(name = "NBS and customs data for China, via Reuters (refinery runs, imports, output)", url = "https://boereport.com/2026/10/20/china-uses-crude-stockpiles-but-rising-oil-imports-may-curtail-draws-russell/"),
      list(name = "EIA monthly crude stocks (checks the US stock figures)", url = "https://www.eia.gov/dnav/pet/pet_stoc_wstk_dcu_nus_m.htm")
    ),
    notes = "Daily flows are modeled estimates. Monthly official data are shaped by daily shipping signals; no public daily country-level data exist.",
    hormuz_target_status = hormuz_targets |> transmute(month = format(month), status, value = hormuz_crude_mbd),
    runs_status = iea_runs |> transmute(month = format(month), status, value = runs_mbd)
  ),
  nodes = nodes |> select(id, label, column, group),
  links = links |> select(id, source, target, origin, p, r, c),
  frames = frames,
  baseline = list(values = baseline_values),
  events = events |> transmute(date = format(date), label, url = source_url, detail, kind)
)

json <- toJSON(export, auto_unbox = TRUE, digits = NA, na = "null", dataframe = "rows")
out_json <- file.path(path_final, "flows.json")
writeLines(json, out_json)
size_mb <- file.size(out_json) / 1024^2
message(sprintf("flows.json: %.2f MB, %d links, %d frames", size_mb, nrow(links), length(frames)))
if (size_mb > 2) {
  stop("flows.json exceeds the 2 MB limit in plan section 5, step 6.")
}

name_of <- function(id) nodes$label[match(id, nodes$id)]
long <- function(df, time_col) {
  df |>
    mutate(
      source = name_of(id_for(producer, 0)),
      route = name_of(id_for(route, 1)),
      target = name_of(id_for(consumer, 2)),
      value = round(mbd, 3)
    ) |>
    select(all_of(time_col), source, route, target, value)
}
write_csv(long(daily, "date"), file.path(path_final, "flows_daily.csv"))
write_csv(long(monthly, "month"), file.path(path_final, "flows_monthly.csv"))
