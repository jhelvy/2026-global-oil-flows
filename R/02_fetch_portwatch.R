# IMF PortWatch daily chokepoint transits and Gulf-export port activity, from the
# public ArcGIS feature services behind the PortWatch download page.
source(file.path("R", "00_setup.R"))

refresh <- FALSE

fetch_group <- function(service, ids, stem) {
  existing <- sort(list.files(path_raw, paste0("^", stem, "_.*csv$"), full.names = TRUE))
  if (length(existing) > 0 && !refresh) {
    return(existing[length(existing)])
  }
  dest <- file.path(path_raw, paste0(stem, "_", Sys.Date(), ".csv"))
  map(ids, \(id) arcgis_query(service, id)) |>
    bind_rows() |>
    write_csv(dest)
  dest
}

# Chokepoints: Hormuz plus context routes ----
chokepoint_ids <- c(
  hormuz = "chokepoint6",
  bab_el_mandeb = "chokepoint4",
  suez = "chokepoint1",
  cape = "chokepoint7"
)
choke <- fetch_group("Daily_Chokepoints_Data", chokepoint_ids, "portwatch_chokepoints") |>
  read_csv() |>
  mutate(date = as.Date(substr(date, 1, 10))) |>
  arrange(portid, date)

stopifnot(all(chokepoint_ids %in% choke$portid))

hormuz <- choke |>
  filter(portid == "chokepoint6") |>
  select(date, n_total, n_tanker, n_cargo, capacity_tanker, capacity) |>
  complete(date = seq(min(date), max(date), by = "day")) |>
  mutate(
    missing = is.na(n_tanker),
    tanker_7d = rollapplyr(n_tanker, 7, mean, na.rm = TRUE, partial = TRUE),
    capacity_tanker_7d = rollapplyr(capacity_tanker, 7, mean, na.rm = TRUE, partial = TRUE)
  )

write_csv(hormuz, file.path(path_interim, "hormuz_daily.csv"))
write_csv(
  choke |> select(date, portname, n_total, n_tanker, capacity_tanker),
  file.path(path_interim, "chokepoints_daily.csv")
)

# Gulf export ports: direct signal for the bypass pipelines ----
# Port ids come from the PortWatch_ports_database service.
port_ids <- c(
  yanbu_king_fahd = "port570",
  yanbu_city = "port1408",
  fujairah = "port362",
  ras_tanura = "port1091",
  al_basrah = "port20",
  mina_al_ahmadi = "port743",
  kharg_island = "port2164"
)
ports <- fetch_group("Daily_Ports_Data", port_ids, "portwatch_ports") |>
  read_csv() |>
  mutate(date = as.Date(substr(date, 1, 10)))

write_csv(
  ports |> select(date, portid, portname, ISO3, portcalls_tanker, import_tanker, export_tanker),
  file.path(path_interim, "ports_daily.csv")
)

message(
  "Hormuz through ", max(hormuz$date), "; missing days: ", sum(hormuz$missing),
  ". Ports: ", paste(sort(unique(ports$portname)), collapse = ", ")
)
