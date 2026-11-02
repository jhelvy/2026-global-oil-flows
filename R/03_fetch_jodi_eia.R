# Monthly country inputs: EIA International and STEO for production and stocks,
# JODI for refinery intake and exports. Writes tidy interim tables only; the
# reconciliation into node groups happens in 04.
source(file.path("R", "00_setup.R"))

# JODI primary oil, 2025 and 2026 ----
jodi_base <- "https://www.jodidata.org/_resources/files/downloads/oil-data/annual-csv/primary/"
jodi_files <- c(
  cached_download(paste0(jodi_base, "2025.csv"), "jodi_primary_2025", "csv"),
  cached_download(paste0(jodi_base, "primaryyear2026.csv"), "jodi_primary_2026", "csv")
)

jodi <- map(jodi_files, read_csv, col_types = cols(.default = "c")) |>
  bind_rows() |>
  filter(
    ENERGY_PRODUCT == "CRUDEOIL",
    UNIT_MEASURE == "KBD",
    FLOW_BREAKDOWN %in% c("INDPROD", "REFINOBS", "TOTEXPSB", "TOTIMPSB", "DIRECUSE", "STATDIFF")
  ) |>
  transmute(
    iso2 = REF_AREA,
    month = as.Date(paste0(TIME_PERIOD, "-01")),
    flow = FLOW_BREAKDOWN,
    mbd = suppressWarnings(as.numeric(OBS_VALUE)) / 1000,
    assessment = as.integer(ASSESSMENT_CODE)
  ) |>
  filter(!is.na(mbd))

write_csv(jodi, file.path(path_interim, "jodi_crude_monthly.csv"))

# EIA International: crude including lease condensate ----
eia_key <- api_key("EIA_API_KEY")
if (is.null(eia_key)) {
  stop("EIA_API_KEY is required for the EIA International query. See API_KEYS.md.")
}

intl_ids <- c("USA", "SAU", "IRQ", "ARE", "KWT", "IRN", "QAT", "BHR", "OMN", "RUS", "CAN", "BRA", "WORL")

f_intl <- list.files(path_raw, "^eia_intl_crude_.*csv$", full.names = TRUE)
if (length(f_intl) == 0) {
  query <- c(
    list(
      api_key = eia_key,
      frequency = "monthly",
      start = "2025-01",
      end = "2026-12",
      length = 5000,
      `data[0]` = "value",
      `facets[productId][]` = "57",
      `facets[activityId][]` = "1",
      `facets[unit][]` = "TBPD"
    ),
    set_names(as.list(intl_ids), rep("facets[countryRegionId][]", length(intl_ids)))
  )
  resp <- request("https://api.eia.gov/v2/international/data/") |>
    req_url_query(!!!query) |>
    req_retry(max_tries = 4, backoff = ~ 5) |>
    req_error(body = \(r) "EIA request failed (URL withheld because it holds the API key)") |>
    req_perform() |>
    resp_body_string() |>
    fromJSON()
  f_intl <- file.path(path_raw, paste0("eia_intl_crude_", Sys.Date(), ".csv"))
  resp$response$data |>
    as_tibble() |>
    select(period, countryRegionId, value, unit) |>
    write_csv(f_intl)
}

intl <- read_csv(sort(f_intl)[length(f_intl)]) |>
  transmute(
    id = countryRegionId,
    month = as.Date(paste0(period, "-01")),
    mbd = as.numeric(value) / 1000
  ) |>
  filter(!is.na(mbd))

stopifnot(all(intl_ids %in% intl$id))
write_csv(intl, file.path(path_interim, "eia_intl_crude_monthly.csv"))

# EIA STEO bulk file ----
f_steo_zip <- cached_download("https://api.eia.gov/bulk/STEO.zip", "eia_steo_bulk", "zip")
steo_lines <- readLines(unz(f_steo_zip, "STEO.txt"), warn = FALSE)

keep_series <- c(
  # Crude production drivers used to extend EIA International past its last month.
  "COPR_SA", "COPR_IZ", "COPR_KU", "COPR_IR", "COPR_RS", "COPR_MU", "COPR_BA",
  "COPR_WORLD", "COPRPUS",
  # Total liquids supply: the only STEO monthly series for these countries.
  "PAPR_TC", "PAPR_QA", "PAPR_CA", "PAPR_BR",
  # World balance. Positive stock change means a net withdrawal.
  "T3_STCHANGE_WORLD", "PATC_WORLD", "PAPR_WORLD",
  # Consumption proxies for gaps in JODI refinery intake.
  "PATC_IN", "PATC_R05", "PATC_OTHER_ASIA", "PATC_CH", "PATC_JA",
  "PATC_OECD_EUROPE", "CORIPUS",
  # US crude stocks, commercial and strategic.
  "COSXPUS", "COSQPUS"
)

parse_series <- function(line) {
  s <- fromJSON(line, simplifyVector = FALSE)
  if (is.null(s$series_id) || !grepl("\\.M$", s$series_id)) {
    return(NULL)
  }
  code <- sub("\\.M$", "", sub("^STEO\\.", "", s$series_id))
  if (!code %in% keep_series) {
    return(NULL)
  }
  tibble(
    series = code,
    name = s$name,
    units = s$units,
    month = as.Date(paste0(map_chr(s$data, 1), "01"), "%Y%m%d"),
    value = map_dbl(s$data, \(x) as.numeric(x[[2]])),
    last_updated = s$last_updated
  )
}

steo <- steo_lines[grepl(paste0("STEO\\.(", paste(keep_series, collapse = "|"), ")\\.M\""), steo_lines)] |>
  map(parse_series) |>
  bind_rows() |>
  filter(month >= as.Date("2025-01-01"), month <= as.Date("2026-12-01"))

write_csv(steo, file.path(path_interim, "steo_monthly.csv"))

message("STEO vintage: ", steo$last_updated[1], ". Series: ", n_distinct(steo$series))
message("Missing STEO series: ", paste(setdiff(keep_series, steo$series), collapse = ", "))
message("EIA International through ", max(intl$month))
message("JODI through ", max(jodi$month))

# Node-group inputs ----
# Production uses EIA International crude including lease condensate, the one
# source with a consistent definition that sums to a world total. JODI's crude
# definition differs by country, so JODI supplies refinery intake and trade only.
months <- seq(as.Date("2026-01-01"), as.Date("2026-10-01"), by = "month")

steo_wide <- steo |>
  select(series, month, value) |>
  pivot_wider(names_from = series, values_from = value)

steo_value <- function(series, m) {
  steo_wide[[series]][match(m, steo_wide$month)]
}

# Extend one EIA International series past its last month with a STEO driver. Months
# the driver lacks (October for most countries) follow STEO world crude production.
extend_production <- function(id, driver) {
  base <- intl |> filter(id == !!id, month %in% months)
  last_month <- max(base$month)
  values <- base$mbd[match(months, base$month)]
  sources <- if_else(is.na(values), NA_character_, "EIA International")
  for (i in which(is.na(values))) {
    ratio <- steo_value(driver, months[i]) / steo_value(driver, months[i - 1])
    used <- driver
    if (is.na(ratio)) {
      ratio <- steo_value("COPR_WORLD", months[i]) / steo_value("COPR_WORLD", months[i - 1])
      used <- "COPR_WORLD"
    }
    values[i] <- values[i - 1] * ratio
    sources[i] <- paste0("Extended with STEO ", used)
  }
  tibble(id = id, month = months, mbd = values, source = sources)
}

production_country <- tribble(
  ~id, ~driver, ~group,
  "USA", "COPRPUS", "usa",
  "SAU", "COPR_SA", "saudi",
  "IRQ", "COPR_IZ", "iraq",
  "ARE", "PAPR_TC", "uae",
  "KWT", "COPR_KU", "kuwait",
  "IRN", "COPR_IR", "iran",
  "QAT", "PAPR_QA", "qatar",
  "BHR", "COPR_BA", "bahrain",
  "OMN", "COPR_MU", "oman",
  "RUS", "COPR_RS", "russia",
  "CAN", "PAPR_CA", "canada",
  "BRA", "PAPR_BR", "brazil",
  "WORL", "COPR_WORLD", "world"
) |>
  mutate(data = map2(id, driver, extend_production)) |>
  select(group, data) |>
  unnest(data) |>
  select(group, id, month, mbd, source)

write_csv(production_country, file.path(path_interim, "production_monthly.csv"))

# Refinery intake plus direct crude burn, by consumer group. Interior gaps carry the
# last report forward. Months past a group's last report follow a STEO liquids-demand
# proxy, and every filled value is flagged.
europe_iso <- c(
  "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
  "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "GB"
)
otherasia_iso <- c("AU", "BD", "BN", "HK", "ID", "MM", "MY", "NP", "NZ", "PG", "PH", "SG", "TH", "TW", "VN")

consumer_groups <- list(
  usa = list(iso = "US", proxy = "CORIPUS"),
  china = list(iso = "CN", proxy = "PATC_CH"),
  india = list(iso = "IN", proxy = "PATC_IN"),
  japan = list(iso = "JP", proxy = "PATC_JA"),
  korea = list(iso = "KR", proxy = "PATC_OTHER_ASIA"),
  europe = list(iso = europe_iso, proxy = "PATC_OECD_EUROPE"),
  otherasia = list(iso = otherasia_iso, proxy = "PATC_OTHER_ASIA")
)

jodi_flow <- function(iso, flow) {
  jodi |>
    filter(iso2 %in% iso, flow == !!flow, month %in% months) |>
    select(iso2, month, mbd) |>
    complete(iso2 = iso, month = months) |>
    arrange(iso2, month)
}

fill_with_proxy <- function(df, proxy) {
  df |>
    group_by(iso2) |>
    mutate(
      reported = !is.na(mbd),
      last_report = if (any(reported)) max(month[reported]) else as.Date(NA),
      last_value = if (any(reported)) mbd[month == last_report][1] else NA_real_,
      ratio = steo_value(proxy, month) / steo_value(proxy, last_report),
      mbd = case_when(
        reported ~ mbd,
        !is.na(last_report) & month > last_report ~ last_value * ratio,
        TRUE ~ NA_real_
      ),
      mbd = na.locf(mbd, na.rm = FALSE),
      mbd = na.locf(mbd, fromLast = TRUE, na.rm = FALSE)
    ) |>
    ungroup() |>
    select(iso2, month, mbd, reported)
}

consumption_country <- imap(consumer_groups, \(g, name) {
  runs <- jodi_flow(g$iso, "REFINOBS") |> fill_with_proxy(g$proxy)
  # Singapore reports crude imports but no refinery intake.
  if ("SG" %in% g$iso) {
    sg_imports <- jodi_flow("SG", "TOTIMPSB") |> fill_with_proxy(g$proxy)
    runs <- runs |>
      filter(iso2 != "SG") |>
      bind_rows(sg_imports)
  }
  direct <- jodi_flow(g$iso, "DIRECUSE") |>
    fill_with_proxy(g$proxy) |>
    transmute(iso2, month, direct = replace_na(mbd, 0))
  runs |>
    left_join(direct, by = c("iso2", "month")) |>
    mutate(
      group = name,
      runs = mbd,
      mbd = replace_na(runs, 0) + replace_na(direct, 0)
    ) |>
    select(group, iso2, month, mbd, reported)
}) |>
  bind_rows()

# JODI's China refinery intake equals imports plus output minus exports in every month, so
# it is apparent supply with stock change forced to zero, not actual runs. Official
# throughput replaces it, and the difference becomes China's stock change in 04.
china_balance <- read_csv(file.path(path_raw, "china_crude_balance.csv"))
stopifnot(all(months %in% china_balance$month))
consumption_country <- consumption_country |>
  mutate(
    china_runs = china_balance$runs_mbd[match(month, china_balance$month)],
    china_ok = china_balance$status[match(month, china_balance$month)] != "assumption",
    mbd = if_else(iso2 == "CN", china_runs, mbd),
    reported = if_else(iso2 == "CN", china_ok, reported)
  ) |>
  select(-china_runs, -china_ok)

write_csv(consumption_country, file.path(path_interim, "consumption_monthly_country.csv"))

# Gap log for milestone 2: the share of each group's volume that is reported.
gaps <- consumption_country |>
  group_by(group, month) |>
  summarise(
    total = sum(mbd),
    reported_share = sum(mbd[reported]) / max(total, 1e-9),
    countries_unreported = paste(iso2[!reported & mbd > 0.02], collapse = " "),
    .groups = "drop"
  )
write_csv(gaps, file.path(path_interim, "gaps_consumption.csv"))
