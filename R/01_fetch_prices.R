# Daily Brent and WTI spot prices from FRED (EIA origin). Uses the keyless CSV
# endpoint, then EIA's own history file to cover FRED's publication lag.
source(file.path("R", "00_setup.R"))

fred_csv <- function(id) {
  f <- cached_download(
    paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=", id, "&cosd=2025-12-01"),
    paste0("fred_", id),
    "csv"
  )
  read_csv(f, na = c("", ".")) |>
    set_names(c("date", "value"))
}

eia_hist <- function(code) {
  f <- cached_download(
    paste0("https://www.eia.gov/dnav/pet/hist_xls/", code, "d.xls"),
    paste0("eia_", code),
    "xls"
  )
  readxl::read_excel(f, sheet = "Data 1", skip = 2) |>
    set_names(c("date", "value")) |>
    mutate(date = as.Date(date)) |>
    filter(date >= as.Date("2025-12-01"), !is.na(value))
}

combine_series <- function(fred, eia) {
  full_join(
    fred |> rename(fred = value),
    eia |> rename(eia = value),
    by = "date"
  ) |>
    arrange(date) |>
    mutate(value = coalesce(fred, eia), source = if_else(is.na(fred), "EIA", "FRED"))
}

brent <- combine_series(fred_csv("DCOILBRENTEU"), eia_hist("RBRTE")) |>
  transmute(date, brent = value, brent_source = source)
wti <- combine_series(fred_csv("DCOILWTICO"), eia_hist("RWTC")) |>
  transmute(date, wti = value)

# Calendar-day series. Weekends and holidays are forward-filled and flagged.
all_days <- tibble(date = seq(min(brent$date), max(brent$date), by = "day"))
prices <- all_days |>
  left_join(brent, by = "date") |>
  left_join(wti, by = "date") |>
  mutate(brent_imputed = is.na(brent), wti_imputed = is.na(wti)) |>
  mutate(across(c(brent, wti), \(x) na.locf(x, na.rm = FALSE)))

write_csv(prices, file.path(path_interim, "prices_daily.csv"))

message(
  "Brent ", min(prices$date), " to ", max(prices$date),
  "; last observation ", max(prices$date[!prices$brent_imputed]),
  " at ", prices$brent[prices$date == max(prices$date[!prices$brent_imputed])]
)
