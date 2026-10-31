# Baseline producer-to-consumer shares from UN Comtrade (HS 2709), domestic flows,
# world balance, and a monthly IPF fit of the trade matrix.
source(file.path("R", "00_setup.R"))

barrels_per_tonne <- 7.33

producers <- c("usa", "saudi", "iraq", "uae", "kuwait", "iran", "othergulf", "russia", "canada", "brazil", "row")
consumers <- c("usa", "china", "india", "japan", "korea", "europe", "mideast", "otherasia", "row")

months <- seq(as.Date("2026-01-01"), as.Date("2026-10-01"), by = "month")
assume <- read_csv(file.path(path_raw, "route_assumptions.csv"))
production <- read_csv(file.path(path_interim, "production_monthly.csv"))
consumption_country <- read_csv(file.path(path_interim, "consumption_monthly_country.csv"))
jodi <- read_csv(file.path(path_interim, "jodi_crude_monthly.csv"))
steo <- read_csv(file.path(path_interim, "steo_monthly.csv"))

# Comtrade bilateral imports ----
fetch_comtrade <- function(year) {
  stem <- paste0("comtrade_hs2709_", year)
  existing <- sort(list.files(path_raw, paste0("^", stem, "_.*csv$"), full.names = TRUE))
  if (length(existing) > 0) {
    return(existing[length(existing)])
  }
  key <- api_key("COMTRADE_API_KEY")
  if (is.null(key)) {
    stop("COMTRADE_API_KEY is required. See API_KEYS.md.")
  }
  resp <- request("https://comtradeapi.un.org/data/v1/get/C/A/HS") |>
    req_headers(`Ocp-Apim-Subscription-Key` = key, .redact = "Ocp-Apim-Subscription-Key") |>
    req_url_query(
      period = year, cmdCode = "2709", flowCode = "M", partner2Code = 0,
      motCode = 0, customsCode = "C00", includeDesc = "true"
    ) |>
    req_retry(max_tries = 4, backoff = ~ 10) |>
    req_timeout(180) |>
    req_perform() |>
    resp_body_string() |>
    fromJSON()
  dest <- file.path(path_raw, paste0(stem, "_", Sys.Date(), ".csv"))
  resp$data |>
    as_tibble() |>
    select(refYear, reporterCode, reporterDesc, partnerCode, partnerDesc, netWgt, qty, primaryValue) |>
    write_csv(dest)
  dest
}

comtrade_raw <- map(c(2024, 2025), \(y) read_csv(fetch_comtrade(y))) |>
  bind_rows() |>
  filter(partnerCode != 0, reporterDesc != partnerDesc) |>
  mutate(kg = coalesce(if_else(netWgt > 0, netWgt, NA_real_), qty, 0))

# Each reporter's newest year with partner detail.
comtrade <- comtrade_raw |>
  group_by(reporterDesc, refYear) |>
  mutate(total = sum(kg)) |>
  filter(total > 0) |>
  group_by(reporterDesc) |>
  filter(refYear == max(refYear)) |>
  ungroup() |>
  mutate(mbd = kg / 1000 * barrels_per_tonne / 365 / 1e6) |>
  select(year = refYear, reporter = reporterDesc, partner = partnerDesc, mbd)

europe_names <- c(
  "Austria", "Belgium", "Bulgaria", "Croatia", "Cyprus", "Czechia", "Denmark", "Estonia",
  "Finland", "France", "Germany", "Greece", "Hungary", "Ireland", "Italy", "Latvia",
  "Lithuania", "Luxembourg", "Malta", "Netherlands", "Poland", "Portugal", "Romania",
  "Slovakia", "Slovenia", "Spain", "Sweden", "United Kingdom"
)
otherasia_names <- c(
  "Australia", "Bangladesh", "Brunei Darussalam", "China, Hong Kong SAR", "Indonesia",
  "Myanmar", "Malaysia", "Nepal", "New Zealand", "Papua New Guinea", "Philippines",
  "Singapore", "Thailand", "Other Asia, nes", "Viet Nam"
)

consumer_group <- function(x) {
  case_when(
    x == "USA" ~ "usa",
    x == "China" ~ "china",
    x == "India" ~ "india",
    x == "Japan" ~ "japan",
    x == "Rep. of Korea" ~ "korea",
    x %in% europe_names ~ "europe",
    x %in% c("Saudi Arabia", "Iraq", "United Arab Emirates", "Kuwait", "Iran", "Qatar", "Bahrain", "Oman") ~ "mideast",
    x %in% otherasia_names ~ "otherasia",
    TRUE ~ "row"
  )
}
producer_group <- function(x) {
  case_when(
    x == "USA" ~ "usa",
    x == "Saudi Arabia" ~ "saudi",
    x == "Iraq" ~ "iraq",
    x == "United Arab Emirates" ~ "uae",
    x == "Kuwait" ~ "kuwait",
    x == "Iran" ~ "iran",
    x %in% c("Qatar", "Bahrain", "Oman") ~ "othergulf",
    x == "Russian Federation" ~ "russia",
    x == "Canada" ~ "canada",
    x == "Brazil" ~ "brazil",
    TRUE ~ "row"
  )
}

pipeline_share <- assume |>
  filter(item == "pipeline_share") |>
  select(group, value) |>
  deframe()

pair_flows <- comtrade |>
  mutate(
    # Relabeled Iranian crude: see route_assumptions.csv.
    partner_fixed = if_else(
      reporter == "China" & partner %in% c("Malaysia", "Indonesia"),
      "Iran",
      partner
    ),
    producer = producer_group(partner_fixed),
    consumer = consumer_group(reporter),
    pipe = case_when(
      partner == "Canada" & reporter == "USA" ~ pipeline_share[["canada>usa"]],
      partner == "Russian Federation" & reporter == "China" ~ pipeline_share[["russia>china"]],
      partner == "Russian Federation" & reporter == "Hungary" ~ pipeline_share[["russia>hungary"]],
      partner == "Russian Federation" & reporter == "Slovakia" ~ pipeline_share[["russia>slovakia"]],
      partner == "Kazakhstan" & reporter == "China" ~ pipeline_share[["kazakhstan>china"]],
      partner == "Kazakhstan" ~ pipeline_share[["kazakhstan>other"]],
      TRUE ~ 0
    )
  )

write_csv(pair_flows, file.path(path_interim, "comtrade_pairs.csv"))

seed_long <- pair_flows |>
  group_by(producer, consumer) |>
  summarise(pipe_share = sum(mbd * pipe) / sum(mbd), mbd = sum(mbd), .groups = "drop")

# Energy Institute inter-area crude matrix: the primary baseline (plan section 3.4).
# Comtrade only splits EI regions into this project's node groups. EI excludes
# intra-Europe trade, so Comtrade supplies Norway and UK flows into Europe.
ei_file <- file.path(path_raw, "manual", "ei_stats_review.xlsx")
if (!file.exists(ei_file)) {
  stop("Missing ", ei_file, ". See DOWNLOADS_NEEDED.md.")
}

ei_raw <- suppressMessages(readxl::read_excel(ei_file, sheet = "Oil - Inter-area movements", col_names = FALSE))
ei_to <- as.character(unlist(ei_raw[3, 2:16]))
ei_cells <- ei_raw[5:25, 1:16] |>
  set_names(c("from", ei_to)) |>
  mutate(across(-from, as.numeric)) |>
  pivot_longer(-from, names_to = "to", values_to = "mt") |>
  # EI's own table converts crude at 7.33 barrels per tonne: 222.295 Mt = 4,464 kb/d.
  mutate(mbd = mt * barrels_per_tonne / 365) |>
  filter(mbd > 0)

ei_from_groups <- list(
  Canada = "canada", Mexico = "row", US = "usa", `S. & Cent. America` = c("brazil", "row"),
  Europe = "row", Russia = "russia", `Other CIS` = "row", Iraq = "iraq", Kuwait = "kuwait",
  `Saudi Arabia` = "saudi", UAE = "uae", `Other Middle East` = c("iran", "othergulf", "row"),
  `North Africa` = "row", `West Africa` = "row", `East & S. Africa` = "row",
  Australasia = "row", China = "row", India = "row", Japan = "row", Singapore = "row",
  `Other Asia Pacific` = "row"
)
ei_to_groups <- list(
  Canada = "row", Mexico = "row", US = "usa", `S. & Cent. America` = "row", Europe = "europe",
  Russia = "row", `Other CIS` = "row", `Middle East` = "mideast", Africa = "row",
  Australasia = "otherasia", China = "china", India = "india", Japan = "japan",
  Singapore = "otherasia", `Other Asia Pacific` = c("korea", "otherasia")
)

comtrade_weight <- function(ps, cs) {
  w <- seed_long |>
    filter(producer %in% ps, consumer %in% cs) |>
    select(producer, consumer, weight = mbd)
  grid <- expand_grid(producer = ps, consumer = cs) |>
    left_join(w, by = c("producer", "consumer")) |>
    mutate(weight = replace_na(weight, 0))
  if (sum(grid$weight) == 0) {
    # No Comtrade record for this pair: assign the whole cell to the first group pair.
    grid$weight[1] <- 1
  }
  grid |> mutate(weight = weight / sum(weight))
}

ei_seed <- ei_cells |>
  mutate(split = map2(from, to, \(f, t) comtrade_weight(ei_from_groups[[f]], ei_to_groups[[t]]))) |>
  unnest(split) |>
  mutate(mbd = mbd * weight) |>
  group_by(producer, consumer) |>
  summarise(mbd = sum(mbd), .groups = "drop")

intra_europe <- pair_flows |>
  filter(partner %in% c(europe_names, "Norway"), consumer == "europe") |>
  group_by(producer, consumer) |>
  summarise(mbd = sum(mbd), .groups = "drop")

seed_final <- bind_rows(ei_seed, intra_europe) |>
  group_by(producer, consumer) |>
  summarise(mbd = sum(mbd), .groups = "drop") |>
  left_join(seed_long |> select(producer, consumer, pipe_share), by = c("producer", "consumer")) |>
  mutate(pipe_share = replace_na(pipe_share, 0))

write_csv(seed_final, file.path(path_interim, "trade_seed.csv"))

ei_russia_exports <- sum(ei_cells$mbd[ei_cells$from == "Russia"])

# Production by node ----
p_wide <- production |>
  select(group, month, mbd) |>
  pivot_wider(names_from = group, values_from = mbd)

prod_group <- p_wide |>
  mutate(
    othergulf = qatar + bahrain + oman,
    row = world - usa - saudi - iraq - uae - kuwait - iran - othergulf - russia - canada - brazil
  )

base_mean <- function(x) mean(x[1:2])

jodi_series <- function(iso, flow) {
  v <- jodi |>
    filter(iso2 %in% iso, flow == !!flow, month %in% months) |>
    group_by(month) |>
    summarise(mbd = sum(mbd), .groups = "drop")
  out <- v$mbd[match(months, v$month)]
  na.locf(na.locf(out, na.rm = FALSE), fromLast = TRUE, na.rm = FALSE)
}

runs_minus_imports <- function(iso) {
  direct <- jodi_series(iso, "DIRECUSE")
  pmax(
    jodi_series(iso, "REFINOBS") + replace_na(direct, 0) - jodi_series(iso, "TOTIMPSB"),
    0
  )
}

hz <- assume |>
  filter(item == "hormuz_base") |>
  select(group, value) |>
  deframe()
adcop_base <- assume$value[assume$item == "bypass_base" & assume$group == "uae"]

# Comtrade partner-reported exports stand in for countries that report no trade.
mirror <- function(name) sum(comtrade$mbd[comtrade$partner == name])

gulf_domestic <- function(p, exports_base) pmin(pmax(base_mean(p) - exports_base, 0), p)

domestic <- list(
  usa = tibble(producer = "usa", consumer = "usa", mbd = pmin(runs_minus_imports("US"), prod_group$usa)),
  canada = tibble(producer = "canada", consumer = "row", mbd = pmin(runs_minus_imports("CA"), prod_group$canada)),
  brazil = tibble(producer = "brazil", consumer = "row", mbd = pmax(prod_group$brazil - jodi_series("BR", "TOTEXPSB"), 0)),
  russia = tibble(
    producer = "russia", consumer = "row",
    mbd = prod_group$russia * (1 - ei_russia_exports / base_mean(prod_group$russia))
  ),
  saudi = tibble(producer = "saudi", consumer = "mideast", mbd = pmin(runs_minus_imports("SA"), prod_group$saudi)),
  kuwait = tibble(producer = "kuwait", consumer = "mideast", mbd = pmin(runs_minus_imports("KW"), prod_group$kuwait)),
  iraq = tibble(producer = "iraq", consumer = "mideast", mbd = gulf_domestic(prod_group$iraq, hz[["iraq"]])),
  uae = tibble(producer = "uae", consumer = "mideast", mbd = gulf_domestic(prod_group$uae, hz[["uae"]] + adcop_base)),
  iran = tibble(producer = "iran", consumer = "mideast", mbd = gulf_domestic(prod_group$iran, hz[["iran"]])),
  qatar = tibble(producer = "othergulf", consumer = "mideast", mbd = gulf_domestic(prod_group$qatar, hz[["qatar"]])),
  oman = tibble(producer = "othergulf", consumer = "mideast", mbd = gulf_domestic(prod_group$oman, mirror("Oman"))),
  bahrain = tibble(producer = "othergulf", consumer = "mideast", mbd = pmax(prod_group$bahrain - jodi_series("BH", "TOTEXPSB"), 0)),
  row_china = tibble(producer = "row", consumer = "china", mbd = pmax(jodi_series("CN", "INDPROD") - jodi_series("CN", "TOTEXPSB"), 0)),
  row_india = tibble(producer = "row", consumer = "india", mbd = jodi_series("IN", "INDPROD")),
  row_europe = tibble(
    producer = "row", consumer = "europe",
    mbd = pmax(
      jodi_series(unique(consumption_country$iso2[consumption_country$group == "europe"]), "INDPROD") -
        jodi_series(unique(consumption_country$iso2[consumption_country$group == "europe"]), "TOTEXPSB"),
      0
    )
  ),
  row_otherasia = tibble(
    producer = "row", consumer = "otherasia",
    mbd = pmax(
      jodi_series(unique(consumption_country$iso2[consumption_country$group == "otherasia"]), "INDPROD") -
        jodi_series(unique(consumption_country$iso2[consumption_country$group == "otherasia"]), "TOTEXPSB"),
      0
    )
  )
) |>
  map(\(d) mutate(d, month = months)) |>
  bind_rows(.id = "flow")

domestic_cells <- domestic |>
  group_by(producer, consumer, month) |>
  summarise(mbd = sum(mbd), .groups = "drop")

# Consumption and world balance ----
# World crude use is IEA global refinery crude throughput. Crude stock change closes
# the gap to production (plan section 5, step 1). STEO's total-liquids stock change
# is kept for comparison only: much of it is product stocks, which IEA says drew
# while lower refinery runs eased the crude market.
iea_runs <- read_csv(file.path(path_raw, "iea_refinery_runs.csv"))
stopifnot(all(months %in% iea_runs$month))

named <- consumption_country |>
  group_by(group, month) |>
  summarise(mbd = sum(mbd), .groups = "drop")

# Bahrain reports refinery intake above its own output; the rest is imported Saudi crude.
mideast_runs <- domestic_cells |>
  filter(consumer == "mideast") |>
  group_by(month) |>
  summarise(mbd = sum(mbd), .groups = "drop") |>
  mutate(
    bahrain_imports = jodi_series("BH", "TOTIMPSB"),
    mbd = mbd + bahrain_imports
  )

world_supply <- tibble(
  month = months,
  production = prod_group$world,
  world_use = iea_runs$runs_mbd[match(months, iea_runs$month)],
  stock_change = world_use - production,
  steo_total_liquids_stock_change = steo$value[steo$series == "T3_STCHANGE_WORLD"][
    match(months, steo$month[steo$series == "T3_STCHANGE_WORLD"])
  ],
  draw = pmax(stock_change, 0),
  build = pmax(-stock_change, 0)
)

named_total <- named |>
  group_by(month) |>
  summarise(named = sum(mbd), .groups = "drop")

consumption <- bind_rows(
  named,
  mideast_runs |> transmute(group = "mideast", month, mbd),
  world_supply |>
    left_join(named_total, by = "month") |>
    left_join(mideast_runs |> select(month, me = mbd), by = "month") |>
    transmute(group = "row", month, mbd = world_use - named - me)
)

write_csv(consumption, file.path(path_interim, "consumption_monthly.csv"))
write_csv(world_supply, file.path(path_interim, "world_balance_monthly.csv"))

# Trade margins ----
prod_long <- prod_group |>
  select(month, all_of(producers)) |>
  pivot_longer(-month, names_to = "producer", values_to = "production")

row_targets <- prod_long |>
  left_join(
    domestic_cells |> group_by(producer, month) |> summarise(dom = sum(mbd), .groups = "drop"),
    by = c("producer", "month")
  ) |>
  mutate(dom = replace_na(dom, 0), exports = production - dom)

col_targets <- consumption |>
  rename(consumer = group, use = mbd) |>
  left_join(
    domestic_cells |> group_by(consumer, month) |> summarise(dom = sum(mbd), .groups = "drop"),
    by = c("consumer", "month")
  ) |>
  mutate(dom = replace_na(dom, 0), imports = use - dom)

write_csv(row_targets, file.path(path_interim, "row_targets.csv"))
write_csv(col_targets, file.path(path_interim, "col_targets.csv"))

if (any(row_targets$exports < -1e-6) || any(col_targets$imports < -1e-6)) {
  print(row_targets |> filter(exports < 0))
  print(col_targets |> filter(imports < 0))
  stop("Negative trade margin. Review domestic flows or residual ROW use.")
}

# Gulf export routes ----
# Bypass pipelines fill first up to their dated cap. Before the war Saudi Arabia and
# the UAE ship only the volume above their IEA Hormuz baseline by pipeline.
cap_table <- assume |> filter(item == "bypass_cap")
bypass_cap <- function(g, m) {
  hit <- cap_table |> filter(group == g, start <= m, end >= m)
  if (nrow(hit) == 0) 0 else hit$value[1]
}

exports_of <- function(g) row_targets$exports[row_targets$producer == g][match(months, row_targets$month[row_targets$producer == g])]

qatar_exports <- pmax(prod_group$qatar - domestic$mbd[domestic$flow == "qatar"], 0)
bahrain_exports <- pmax(prod_group$bahrain - domestic$mbd[domestic$flow == "bahrain"], 0)
oman_exports <- pmax(prod_group$oman - domestic$mbd[domestic$flow == "oman"], 0)

gulf_routes <- map(c("saudi", "uae", "iraq", "kuwait", "iran", "othergulf"), \(g) {
  x <- exports_of(g)
  caps <- map_dbl(months, \(m) bypass_cap(g, m))
  prewar <- months < as.Date("2026-03-01")
  base_hormuz <- if (g %in% names(hz)) hz[[g]] else 0
  bypass <- case_when(
    g %in% c("saudi", "uae") & prewar ~ pmin(caps, pmax(x - base_hormuz, 0)),
    TRUE ~ pmin(caps, x)
  )
  other <- if (g == "othergulf") pmin(oman_exports, x) else rep(0, length(x))
  tibble(producer = g, month = months, exports = x, bypass = bypass, other = other, hormuz = pmax(x - bypass - other, 0))
}) |>
  bind_rows()

# Hormuz crude targets ----
# Where IEA reports Hormuz crude for a month, the flow matches it. Production minus
# domestic use cannot show Gulf storage, which IEA says filled during the closure and
# emptied in June. Below target, the gap is a release from storage, carried by the
# stock node through Hormuz. Above target, Hormuz producers store the excess. Either
# way gross stock flows move together, so net stock change and consumer totals hold.
hormuz_targets <- read_csv(file.path(path_raw, "hormuz_crude_targets.csv"))

gulf_routes <- gulf_routes |>
  group_by(month) |>
  mutate(
    total_hormuz = sum(hormuz),
    target = hormuz_targets$hormuz_crude_mbd[match(month, hormuz_targets$month)],
    excess = pmax(replace_na(total_hormuz - target, 0), 0),
    release = pmax(replace_na(target - total_hormuz, 0), 0),
    stored = if_else(total_hormuz > 0, excess * hormuz / total_hormuz, 0),
    hormuz = hormuz - stored,
    exports = exports - stored
  ) |>
  ungroup()

gulf_storage <- gulf_routes |>
  select(producer, month, stored, release)
write_csv(gulf_routes |> select(producer, month, exports, bypass, other, hormuz, stored, release), file.path(path_interim, "gulf_routes_monthly.csv"))
write_csv(gulf_storage, file.path(path_interim, "gulf_storage_monthly.csv"))

storage_month <- gulf_storage |>
  group_by(month) |>
  summarise(stored = sum(stored), release = first(release), .groups = "drop")

row_targets <- row_targets |>
  left_join(gulf_storage |> select(producer, month, stored), by = c("producer", "month")) |>
  mutate(exports = exports - replace_na(stored, 0)) |>
  select(-stored)

world_supply <- world_supply |>
  left_join(storage_month, by = "month") |>
  mutate(
    draw = draw + stored + release,
    build = build + release,
    build_total = build + stored
  )

write_csv(world_supply, file.path(path_interim, "world_balance_monthly.csv"))
write_csv(row_targets, file.path(path_interim, "row_targets.csv"))

# Monthly IPF ----
ipf <- function(seed, row_sum, col_sum, tol = 1e-7, max_iter = 5000) {
  m <- seed
  for (i in seq_len(max_iter)) {
    r <- rowSums(m)
    m <- m * ifelse(r > 0, row_sum / r, 0)
    k <- colSums(m)
    m <- sweep(m, 2, ifelse(k > 0, col_sum / k, 0), "*")
    err <- max(abs(rowSums(m) - row_sum), abs(colSums(m) - col_sum))
    if (err < tol) {
      break
    }
  }
  list(m = m, iter = i, err = err)
}

rows_all <- c(producers, "stock")
cols_all <- c(consumers, "stock")
seed <- matrix(0.001, length(rows_all), length(cols_all), dimnames = list(rows_all, cols_all))
for (k in seq_len(nrow(seed_final))) {
  seed[seed_final$producer[k], seed_final$consumer[k]] <-
    seed[seed_final$producer[k], seed_final$consumer[k]] + seed_final$mbd[k]
}

base_rows <- row_targets |>
  filter(month <= as.Date("2026-02-01")) |>
  group_by(producer) |>
  summarise(exports = mean(exports), .groups = "drop") |>
  deframe()
base_cols <- col_targets |>
  filter(month <= as.Date("2026-02-01")) |>
  group_by(consumer) |>
  summarise(imports = mean(imports), .groups = "drop") |>
  deframe()

# ROW-to-ROW has no complete bilateral record, so its seed is the baseline residual.
seed["row", "row"] <- max(base_cols[["row"]] - sum(seed[producers[producers != "row"], "row"]), 0.5)
# Stock draws go to importers in proportion to their imports, never to the Gulf.
seed["stock", consumers] <- base_cols[consumers] / sum(base_cols[consumers])
seed["stock", "mideast"] <- 0
seed["stock", "stock"] <- 0
# Stock builds come from exporters in proportion to their exports.
seed[producers, "stock"] <- base_rows[producers] / sum(base_rows[producers])

fits <- map(months, \(mo) {
  rows <- row_targets |> filter(month == mo)
  cols <- col_targets |> filter(month == mo)
  w <- world_supply |> filter(month == mo)
  row_sum <- c(rows$exports[match(producers, rows$producer)], stock = w$draw)
  col_sum <- c(cols$imports[match(consumers, cols$consumer)], stock = w$build)
  names(row_sum) <- rows_all
  names(col_sum) <- cols_all
  gap <- sum(row_sum) - sum(col_sum)
  if (abs(gap) > 1e-6) {
    stop("Margins differ by ", gap, " in ", mo)
  }
  fit <- ipf(seed, row_sum, col_sum)
  list(month = mo, iter = fit$iter, err = fit$err, m = fit$m)
})

convergence <- tibble(
  month = months,
  iterations = map_int(fits, "iter"),
  max_margin_error = map_dbl(fits, "err")
)
print(as.data.frame(convergence))
if (any(convergence$max_margin_error > 1e-4)) {
  stop("IPF did not converge in every month.")
}
write_csv(convergence, file.path(path_interim, "ipf_convergence.csv"))

trade <- map(fits, \(f) {
  as_tibble(f$m, rownames = "producer") |>
    pivot_longer(-producer, names_to = "consumer", values_to = "mbd") |>
    mutate(month = f$month)
}) |>
  bind_rows() |>
  filter(mbd > 0)

write_csv(trade, file.path(path_interim, "trade_monthly.csv"))
write_csv(domestic_cells, file.path(path_interim, "domestic_monthly.csv"))

message("IPF converged in all ", length(months), " months.")
