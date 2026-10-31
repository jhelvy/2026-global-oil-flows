# Split the monthly producer-to-consumer flows by route. Output: one row per
# producer, route, consumer, and month.
source(file.path("R", "00_setup.R"))

trade <- read_csv(file.path(path_interim, "trade_monthly.csv"))
domestic <- read_csv(file.path(path_interim, "domestic_monthly.csv"))
gulf <- read_csv(file.path(path_interim, "gulf_routes_monthly.csv"))
seed <- read_csv(file.path(path_interim, "trade_seed.csv"))
storage <- read_csv(file.path(path_interim, "gulf_storage_monthly.csv"))
balance <- read_csv(file.path(path_interim, "world_balance_monthly.csv"))

gulf_producers <- unique(gulf$producer)

gulf_shares <- gulf |>
  mutate(
    hormuz = if_else(exports > 0, hormuz / exports, 0),
    bypass = if_else(exports > 0, bypass / exports, 0),
    seaborne = if_else(exports > 0, other / exports, 0)
  ) |>
  select(producer, month, hormuz, bypass, seaborne) |>
  pivot_longer(c(hormuz, bypass, seaborne), names_to = "route", values_to = "share") |>
  filter(share > 0)

gulf_flows <- trade |>
  filter(producer %in% gulf_producers) |>
  inner_join(gulf_shares, by = c("producer", "month"), relationship = "many-to-many") |>
  transmute(producer, route, consumer, month, mbd = mbd * share)

other_flows <- trade |>
  filter(!producer %in% gulf_producers, producer != "stock") |>
  left_join(seed |> select(producer, consumer, pipe_share), by = c("producer", "consumer")) |>
  mutate(pipe_share = replace_na(pipe_share, 0)) |>
  # ROW-to-ROW lacks bilateral detail; it is reported as within-region flow.
  mutate(within_region = producer == "row" & consumer == "row") |>
  transmute(
    producer, consumer, month, within_region,
    pipeline = if_else(within_region, 0, mbd * pipe_share),
    seaborne = if_else(within_region, 0, mbd * (1 - pipe_share)),
    domestic = if_else(within_region, mbd, 0)
  ) |>
  pivot_longer(c(pipeline, seaborne, domestic), names_to = "route", values_to = "mbd") |>
  select(producer, route, consumer, month, mbd) |>
  filter(mbd > 0)

# Stock draws reach refiners from local tanks, so they carry no transit route. The
# exception is the release from Gulf storage, which leaves through Hormuz.
stock_flows <- trade |>
  filter(producer == "stock") |>
  left_join(balance |> select(month, draw, release), by = "month") |>
  mutate(hormuz = if_else(draw > 0, mbd * release / draw, 0), domestic = mbd - hormuz) |>
  select(producer, consumer, month, hormuz, domestic) |>
  pivot_longer(c(hormuz, domestic), names_to = "route", values_to = "mbd") |>
  filter(mbd > 0)

domestic_flows <- domestic |>
  transmute(producer, route = "domestic", consumer, month, mbd)

stored_flows <- storage |>
  transmute(producer, route = "domestic", consumer = "stock", month, mbd = stored) |>
  filter(mbd > 0)

routes <- bind_rows(gulf_flows, other_flows, stock_flows, domestic_flows, stored_flows) |>
  group_by(producer, route, consumer, month) |>
  summarise(mbd = sum(mbd), .groups = "drop") |>
  filter(mbd > 1e-6)

write_csv(routes, file.path(path_interim, "flows_monthly_model.csv"))
message("Monthly triples: ", n_distinct(paste(routes$producer, routes$route, routes$consumer)))
