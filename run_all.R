# Rerun the full pipeline. Cached downloads in data/raw are reused.
scripts <- c(
  "01_fetch_prices.R", "02_fetch_portwatch.R", "03_fetch_jodi_eia.R",
  "04_build_trade_matrix.R", "05_routes.R", "06_daily_model.R",
  "07_validate.R", "08_export_json.R"
)
for (s in scripts) {
  message("\n== ", s)
  env <- new.env(parent = globalenv())
  sys.source(file.path("R", s), envir = env)
}
