# Validation checks from plan section 5, step 5, plus calibration comparisons and QA
# plots. Stops with an error when a required check fails.
source(file.path("R", "00_setup.R"))
library(cowplot)

font <- "Roboto Condensed"

daily <- read_csv(file.path(path_interim, "flows_daily_model.csv"))
monthly <- read_csv(file.path(path_interim, "flows_monthly_model.csv"))
production <- read_csv(file.path(path_interim, "production_monthly.csv"))
consumption <- read_csv(file.path(path_interim, "consumption_monthly.csv"))
balance <- read_csv(file.path(path_interim, "world_balance_monthly.csv"))
targets <- read_csv(file.path(path_raw, "calibration_targets.csv"))
gulf <- read_csv(file.path(path_interim, "gulf_routes_monthly.csv"))

results <- list()
check <- function(name, ok, detail) {
  results[[length(results) + 1]] <<- tibble(check = name, pass = ok, detail = detail)
  message(if (ok) "PASS  " else "FAIL  ", name, ": ", detail)
}

# Daily balance: left = middle = right ----
day_totals <- daily |>
  group_by(date) |>
  summarise(total = sum(mbd), .groups = "drop") |>
  left_join(
    daily |>
      group_by(date, producer) |>
      summarise(v = sum(mbd), .groups = "drop") |>
      group_by(date) |>
      summarise(left = sum(v), .groups = "drop"),
    by = "date"
  ) |>
  left_join(
    daily |>
      group_by(date, consumer) |>
      summarise(v = sum(mbd), .groups = "drop") |>
      group_by(date) |>
      summarise(right = sum(v), .groups = "drop"),
    by = "date"
  ) |>
  left_join(
    daily |>
      group_by(date, route) |>
      summarise(v = sum(mbd), .groups = "drop") |>
      group_by(date) |>
      summarise(middle = sum(v), .groups = "drop"),
    by = "date"
  )
gap <- max(abs(day_totals$left - day_totals$right), abs(day_totals$left - day_totals$middle))
check("Daily left = middle = right", gap <= 0.01, sprintf("max gap %.2e mb/d", gap))

check("No negative flows", min(daily$mbd) >= 0, sprintf("minimum %.4f mb/d", min(daily$mbd)))

# Monthly means of daily series against the monthly inputs ----
daily_month <- daily |>
  mutate(month = floor_date(date, "month"))

triple_means <- daily_month |>
  group_by(producer, route, consumer, month) |>
  summarise(daily_mean = mean(mbd), .groups = "drop") |>
  left_join(monthly, by = c("producer", "route", "consumer", "month")) |>
  mutate(mbd = replace_na(mbd, 0), abs_gap = abs(daily_mean - mbd))
check(
  "Monthly mean of each flow matches input", max(triple_means$abs_gap) <= 0.005,
  sprintf("max gap %.4f mb/d", max(triple_means$abs_gap))
)

prod_input <- production |>
  filter(group != "world") |>
  mutate(group = if_else(group %in% c("qatar", "bahrain", "oman"), "othergulf", group)) |>
  group_by(group, month) |>
  summarise(input = sum(mbd), .groups = "drop")
prod_daily <- daily_month |>
  filter(producer != "stock") |>
  group_by(producer, date, month) |>
  summarise(v = sum(mbd), .groups = "drop") |>
  group_by(group = producer, month) |>
  summarise(model = mean(v), .groups = "drop")
prod_check <- prod_daily |>
  inner_join(prod_input, by = c("group", "month")) |>
  mutate(rel = abs(model / input - 1))
check(
  "Monthly producer means within 1% of inputs", max(prod_check$rel) <= 0.01,
  sprintf("worst %.3f%% (%s)", 100 * max(prod_check$rel), prod_check$group[which.max(prod_check$rel)])
)

cons_daily <- daily_month |>
  filter(consumer != "stock") |>
  group_by(consumer, date, month) |>
  summarise(v = sum(mbd), .groups = "drop") |>
  group_by(group = consumer, month) |>
  summarise(model = mean(v), .groups = "drop")
cons_check <- cons_daily |>
  inner_join(consumption |> rename(input = mbd), by = c("group", "month")) |>
  mutate(rel = abs(model / input - 1))
check(
  "Monthly consumer means within 1% of inputs", max(cons_check$rel) <= 0.01,
  sprintf("worst %.3f%% (%s)", 100 * max(cons_check$rel), cons_check$group[which.max(cons_check$rel)])
)

# Pre-war Hormuz share and the size of the shock ----
hormuz_day <- daily |>
  filter(route == "hormuz") |>
  group_by(date) |>
  summarise(mbd = sum(mbd), .groups = "drop")
prewar_hormuz <- mean(hormuz_day$mbd[hormuz_day$date <= date_baseline_end])
world_prewar <- mean(balance$production[balance$month <= as.Date("2026-02-01")])
share <- prewar_hormuz / world_prewar
check(
  "Pre-war Hormuz near 20% of world supply", share >= 0.15 && share <= 0.22,
  sprintf("%.1f mb/d, %.1f%% of crude supply", prewar_hormuz, 100 * share)
)

supply_drop <- mean(balance$production[balance$month <= as.Date("2026-02-01")]) -
  mean(balance$production[balance$month %in% as.Date(c("2026-03-01", "2026-04-01"))])
check(
  "Mar-Apr crude supply loss plausible against IEA", supply_drop >= 8 && supply_drop <= 14,
  sprintf("%.1f mb/d crude; IEA total oil loss 12.8 mb/d by April", supply_drop)
)

# Calibration table: modeled values beside published figures ----
month_of <- function(x) as.Date(paste0(x, "-01"))
hormuz_monthly <- hormuz_day |>
  group_by(month = floor_date(date, "month")) |>
  summarise(mbd = mean(mbd), .groups = "drop")
quarter_mean <- function(from, to) {
  days <- hormuz_day |> filter(date >= from, date <= to)
  mean(days$mbd)
}
# IEA's Gulf export figures exclude Oman, which loads outside the strait.
gulf_total <- gulf |>
  group_by(month) |>
  summarise(exports = sum(exports - other), bypass = sum(bypass), .groups = "drop")
release_by_month <- gulf |>
  group_by(month) |>
  summarise(release = first(release), .groups = "drop")

stock_cells <- read_csv(file.path(path_interim, "stock_cells_monthly.csv"))
stock_net <- function(group, month) {
  stock_cells$net_local[stock_cells$consumer == group & stock_cells$month == as.Date(month)]
}

observations <- read_csv(file.path(path_raw, "iea_stock_observations.csv"))
us_stock <- read_csv(file.path(path_interim, "us_stock_change_monthly.csv"))
observed <- function(what, mon) {
  observations$change_mbd[observations$item == what & observations$month == as.Date(mon)]
}
storage_change <- function(mon) {
  g <- gulf |> filter(month == as.Date(mon))
  sum(g$stored) - g$release[1]
}
world_change <- function(mon) -balance$stock_change[balance$month == as.Date(mon)]
gulf_crude <- function(mon) {
  g <- gulf |> filter(month == as.Date(mon))
  sum(g$exports - g$other) + g$release[1]
}
saudi_hormuz <- function(mon) gulf$hormuz[gulf$producer == "saudi" & gulf$month == as.Date(mon)]
gulf_output <- function(group, mon) production$mbd[production$group == group & production$month == as.Date(mon)]
consumer_runs <- function(groups, mon) sum(consumption$mbd[consumption$group %in% groups & consumption$month == as.Date(mon)])
asia <- c("japan", "korea", "india", "otherasia")

comparison <- tribble(
  ~measure, ~period, ~model, ~published,
  # Gulf storage comes from output, refinery use and exports. IEA measures it separately from
  # satellites and tanker tracking, so this is a real test. Builds are positive.
  "Gulf crude storage change, IEA", "Mar 2026", storage_change("2026-03-01"), observed("gulf_storage_crude", "2026-03-01"),
  "Gulf crude storage change, IEA", "Apr 2026", storage_change("2026-04-01"), observed("gulf_storage_crude", "2026-04-01"),
  "Gulf crude storage change, IEA", "May 2026", storage_change("2026-05-01"), observed("gulf_storage_crude", "2026-05-01"),
  "Gulf crude storage change, IEA", "Jun 2026", storage_change("2026-06-01"), observed("gulf_storage_crude", "2026-06-01"),
  # World crude stock change: IEA runs less EIA output, against what IEA observed.
  "World crude stock change, IEA observed", "Jan 2026", world_change("2026-01-01"), observed("world_crude_observed", "2026-01-01"),
  "World crude stock change, IEA observed", "Feb 2026", world_change("2026-02-01"), observed("world_crude_observed", "2026-02-01"),
  "World crude stock change, IEA observed", "Mar 2026", world_change("2026-03-01"), observed("world_crude_observed", "2026-03-01"),
  "World crude stock change, IEA observed", "Apr 2026", world_change("2026-04-01"), observed("world_crude_observed", "2026-04-01"),
  "World crude stock change, IEA observed", "May 2026", world_change("2026-05-01"), observed("world_crude_observed", "2026-05-01"),
  "World crude stock change, IEA observed", "Jun 2026", world_change("2026-06-01"), observed("world_crude_observed", "2026-06-01"),
  # Later route figures that are not model inputs.
  "Hormuz crude, Kpler", "Mar 2026", hormuz_monthly$mbd[hormuz_monthly$month == as.Date("2026-03-01")], 1.8,
  "Saudi crude crossing Hormuz, Kpler", "Aug 2026", saudi_hormuz("2026-08-01"), 0.7,
  "Saudi crude crossing Hormuz, Kpler", "Sep 2026", saudi_hormuz("2026-09-01"), 2.8,
  "Gulf crude leaving outside the strait, Kpler", "Sep 2026", sum(gulf_total$bypass[gulf_total$month == as.Date("2026-09-01")]) + sum(gulf$other[gulf$month == as.Date("2026-09-01")]), 0.4 * 16.5,
  # Output: IEA excludes condensate and EIA includes it, so EIA should run somewhat higher.
  "Saudi crude output, IEA", "Apr 2026", gulf_output("saudi", "2026-04-01"), 6.36,
  "Saudi crude output, IEA", "Jun 2026", gulf_output("saudi", "2026-06-01"), 7.34,
  "Iraq crude output, IEA", "Apr 2026", gulf_output("iraq", "2026-04-01"), 1.45,
  "Iraq crude output, IEA", "Jun 2026", gulf_output("iraq", "2026-06-01"), 1.96,
  "Kuwait crude output, IEA", "Apr 2026", gulf_output("kuwait", "2026-04-01"), 0.57,
  "Kuwait crude output, IEA", "Jun 2026", gulf_output("kuwait", "2026-06-01"), 1.37,
  "Iran crude output, IEA", "Apr 2026", gulf_output("iran", "2026-04-01"), 3.36,
  "Iran crude output, IEA", "Jun 2026", gulf_output("iran", "2026-06-01"), 2.30,
  # Consumers. China's official runs are an input, so IEA's estimate is the independent view.
  "China runs, IEA", "Mar 2026", consumer_runs("china", "2026-03-01"), 14.6,
  "China runs, IEA", "Apr 2026", consumer_runs("china", "2026-04-01"), 13.4,
  "China runs, IEA", "May 2026", consumer_runs("china", "2026-05-01"), 12.7,
  "China runs, IEA", "Jun 2026", consumer_runs("china", "2026-06-01"), 13.1,
  "Asia outside China, IEA Asia Oceania plus Other Asia", "Mar 2026", consumer_runs(asia, "2026-03-01"), 15.9,
  "Asia outside China, IEA Asia Oceania plus Other Asia", "Apr 2026", consumer_runs(asia, "2026-04-01"), 14.2,
  "Asia outside China, IEA Asia Oceania plus Other Asia", "May 2026", consumer_runs(asia, "2026-05-01"), 14.6,
  "Asia outside China, IEA Asia Oceania plus Other Asia", "Jun 2026", consumer_runs(asia, "2026-06-01"), 15.1,
  "Hormuz crude, EIA", "1Q26", quarter_mean(date_start, as.Date("2026-03-31")), 10.9,
  "Hormuz crude, EIA", "2Q26", quarter_mean(as.Date("2026-04-01"), as.Date("2026-06-30")), 3.7,
  "Hormuz crude, IEA", "2025 vs pre-war 2026", prewar_hormuz, 14.95,
  "Hormuz crude, IEA", "Mar 2026", hormuz_monthly$mbd[hormuz_monthly$month == as.Date("2026-03-01")], 1.9,
  "Gulf crude exports, IEA", "Feb 2026", gulf_total$exports[gulf_total$month == as.Date("2026-02-01")], 18.4,
  "Gulf crude exports, IEA", "Apr 2026", gulf_total$exports[gulf_total$month == as.Date("2026-04-01")] + release_by_month$release[release_by_month$month == as.Date("2026-04-01")], 8.4,
  "Gulf crude exports, IEA", "May 2026", gulf_total$exports[gulf_total$month == as.Date("2026-05-01")] + release_by_month$release[release_by_month$month == as.Date("2026-05-01")], 7.9,
  "Gulf crude exports, IEA", "Jun 2026", gulf_total$exports[gulf_total$month == as.Date("2026-06-01")] + release_by_month$release[release_by_month$month == as.Date("2026-06-01")], 13.2,
  "Yanbu + Fujairah (model crude; IEA all oil)", "Feb 2026", gulf_total$bypass[gulf_total$month == as.Date("2026-02-01")], 4.1,
  "Yanbu + Fujairah (model crude; IEA all oil)", "Jun 2026", gulf_total$bypass[gulf_total$month == as.Date("2026-06-01")], 7.8,
  "Yanbu + Fujairah (model crude; IEA all oil)", "Aug 2026", gulf_total$bypass[gulf_total$month == as.Date("2026-08-01")], 5.5,
  "Middle East runs, IEA", "Feb 2026", consumption$mbd[consumption$group == "mideast" & consumption$month == as.Date("2026-02-01")], 10.3,
  "Europe runs, IEA", "Apr 2026", consumption$mbd[consumption$group == "europe" & consumption$month == as.Date("2026-04-01")], 10.6,
  "China runs, NBS-based", "Apr 2026", consumption$mbd[consumption$group == "china" & consumption$month == as.Date("2026-04-01")], 13.3,
  "China runs, NBS-based", "Jun 2026", consumption$mbd[consumption$group == "china" & consumption$month == as.Date("2026-06-01")], 12.38,
  # Stock change, draws positive. IEA's China figures are satellite-based, so they test the
  # sign and timing of the official-data estimate, not its exact size.
  "China crude stock draw, IEA satellite", "Mar 2026", stock_net("china", "2026-03-01"), -1.2,
  "China crude stock draw, IEA satellite", "Apr 2026", stock_net("china", "2026-04-01"), 0.2,
  "China crude stock draw, IEA satellite", "May 2026", stock_net("china", "2026-05-01"), 0.3,
  "China crude stock draw, IEA satellite", "Jun 2026", stock_net("china", "2026-06-01"), 1.4
) |>
  bind_rows(
    # JODI's US figures against EIA's own stock levels, commercial plus SPR.
    us_stock |>
      filter(month <= as.Date("2026-08-01")) |>
      transmute(
        measure = "US crude stock draw incl. SPR, EIA", period = format(month, "%b %Y"),
        model = map_dbl(month, \(m) stock_net("usa", m)), published = net
      )
  ) |>
  mutate(gap_pct = 100 * (model / published - 1), gap_mbd = model - published)

write_csv(comparison, file.path(path_qa, "calibration_comparison.csv"))
print(comparison |> mutate(across(where(is.numeric), \(x) round(x, 2))) |> as.data.frame())

# QA plots ----
plot_theme <- function() {
  theme_minimal_grid(font_family = font, font_size = 11) +
    theme(
      plot.title.position = "plot",
      plot.caption.position = "plot",
      legend.position = "none",
      strip.background = element_rect(fill = "grey80", color = NA),
      panel.grid.minor = element_blank(),
      panel.background = element_rect(fill = "white", color = NA),
      plot.background = element_rect(fill = "white", color = NA)
    )
}

war_line <- geom_vline(xintercept = date_war, linetype = "dashed", color = "grey50")

by_producer <- daily |>
  group_by(date, node = producer) |>
  summarise(mbd = sum(mbd), .groups = "drop")
by_route <- daily |>
  group_by(date, node = route) |>
  summarise(mbd = sum(mbd), .groups = "drop")
by_consumer <- daily |>
  group_by(date, node = consumer) |>
  summarise(mbd = sum(mbd), .groups = "drop")

save_each <- function(df, prefix) {
  walk(unique(df$node), \(n) {
    p <- df |>
      filter(node == n) |>
      ggplot() +
      war_line +
      geom_line(aes(x = date, y = mbd), color = "#980000") +
      scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
      labs(x = NULL, y = "mb/d", title = paste0(prefix, ": ", n), caption = "Modeled daily flow. Dashed line: Feb 28, 2026.") +
      plot_theme()
    ggsave(file.path(path_qa, paste0(prefix, "_", n, ".png")), p, width = 7, height = 3.5, dpi = 150)
  })
}
save_each(by_producer, "producer")
save_each(by_route, "route")

facet_plot <- function(df, title, file) {
  p <- df |>
    ggplot() +
    war_line +
    geom_line(aes(x = date, y = mbd), color = "#980000") +
    facet_wrap(vars(node), scales = "free_y") +
    scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
    labs(x = NULL, y = "mb/d", title = title) +
    plot_theme() +
    panel_border()
  ggsave(file.path(path_qa, file), p, width = 12, height = 8, dpi = 150)
}
facet_plot(by_producer, "Producers", "overview_producers.png")
facet_plot(by_route, "Routes", "overview_routes.png")
facet_plot(by_consumer, "Consumers", "overview_consumers.png")

# Milestone 1 plot: price and the tanker signal.
prices <- read_csv(file.path(path_interim, "prices_daily.csv"))
hz <- read_csv(file.path(path_interim, "hormuz_daily.csv"))
m1 <- bind_rows(
  prices |> transmute(date, series = "Brent spot (USD/bbl)", value = brent),
  hz |> transmute(date, series = "Hormuz tanker transits (7-day mean)", value = tanker_7d)
) |>
  filter(date >= date_start) |>
  ggplot() +
  war_line +
  geom_line(aes(x = date, y = value), color = "#980000") +
  facet_wrap(vars(series), ncol = 1, scales = "free_y") +
  scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
  labs(
    x = NULL, y = NULL, title = "Brent and Hormuz tanker traffic, 2026",
    caption = "Data sources: FRED (DCOILBRENTEU), EIA, IMF PortWatch"
  ) +
  plot_theme() +
  panel_border()
ggsave(file.path(path_qa, "milestone1_price_hormuz.png"), m1, width = 9, height = 5.5, dpi = 150)

# Hormuz: the model against the unscaled tanker-ratio formula in plan section 5, step 4.
tanker_base <- mean(hz$tanker_7d[hz$date >= date_start & hz$date <= date_baseline_end])
compare_hz <- hormuz_day |>
  rename(model = mbd) |>
  left_join(hz |> select(date, tanker_7d), by = "date") |>
  mutate(raw_ratio = prewar_hormuz * tanker_7d / tanker_base)
p_hz <- compare_hz |>
  pivot_longer(c(model, raw_ratio)) |>
  ggplot() +
  war_line +
  geom_line(aes(x = date, y = value, color = name)) +
  scale_color_manual(values = c(model = "#980000", raw_ratio = "grey60")) +
  scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
  labs(
    x = NULL, y = "mb/d", title = "Hormuz crude: model (red) against unscaled AIS tanker ratio (gray)",
    subtitle = "IEA and EIA monthly figures exceed the AIS ratio; EIA calls Hormuz AIS data especially unreliable since February",
    caption = "Data sources: IMF PortWatch, IEA, EIA"
  ) +
  plot_theme()
ggsave(file.path(path_qa, "hormuz_model_vs_ais.png"), p_hz, width = 9, height = 4.5, dpi = 150)

results_table <- bind_rows(results)
write_csv(results_table, file.path(path_qa, "validation_results.csv"))
if (!all(results_table$pass)) {
  stop("Validation failed: ", paste(results_table$check[!results_table$pass], collapse = "; "))
}
message("All validation checks passed.")
