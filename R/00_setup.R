# Shared paths and helpers. Sourced by every pipeline script.
suppressPackageStartupMessages({
  library(tidyverse)
  library(httr2)
  library(jsonlite)
  library(lubridate)
  library(zoo)
})

options(dplyr.width = Inf, readr.show_col_types = FALSE)

path_raw <- file.path("data", "raw")
path_interim <- file.path("data", "interim")
path_final <- file.path("data", "final")
path_qa <- "qa"

for (p in c(path_raw, path_interim, path_final, path_qa)) {
  dir.create(p, recursive = TRUE, showWarnings = FALSE)
}

date_start <- as.Date("2026-01-01")
date_war <- as.Date("2026-02-28")
date_baseline_end <- as.Date("2026-02-27")

# Cache a download under data/raw with the download date in its name. Reuses the
# newest cached copy unless `refresh` is TRUE, so reruns never need live endpoints.
cached_download <- function(url, stem, ext, refresh = FALSE) {
  existing <- sort(list.files(
    path_raw,
    pattern = paste0("^", stem, "_[0-9]{4}-[0-9]{2}-[0-9]{2}\\.", ext, "$"),
    full.names = TRUE
  ))
  if (length(existing) > 0 && !refresh) {
    return(existing[length(existing)])
  }
  dest <- file.path(path_raw, paste0(stem, "_", Sys.Date(), ".", ext))
  req <- request(url) |>
    req_retry(max_tries = 4, backoff = ~ 5) |>
    req_timeout(600)
  req_perform(req, path = dest)
  dest
}

latest_cached <- function(stem, ext) {
  existing <- sort(list.files(
    path_raw,
    pattern = paste0("^", stem, "_[0-9]{4}-[0-9]{2}-[0-9]{2}\\.", ext, "$"),
    full.names = TRUE
  ))
  if (length(existing) == 0) {
    stop("No cached file for ", stem, ". Run the fetch script first.")
  }
  existing[length(existing)]
}

# Page through an ArcGIS feature service for one port or chokepoint id. The service
# rejects IN and date filters, and fails intermittently, so each page is retried.
arcgis_query <- function(service, portid, min_year = 2025, page_size = 1000) {
  base <- paste0(
    "https://services9.arcgis.com/weJ1QsnbMYJlCHdG/arcgis/rest/services/",
    service,
    "/FeatureServer/0/query"
  )
  where <- sprintf("portid='%s' AND year>=%d", portid, min_year)
  fetch_page <- function(offset, tries = 6) {
    for (i in seq_len(tries)) {
      res <- request(base) |>
        req_url_query(
          where = where,
          outFields = "*",
          orderByFields = "date ASC",
          resultOffset = offset,
          resultRecordCount = page_size,
          f = "json"
        ) |>
        req_retry(max_tries = 4, backoff = ~ 5) |>
        req_timeout(120) |>
        req_perform() |>
        resp_body_string() |>
        fromJSON(flatten = TRUE)
      if (is.null(res$error)) {
        return(res)
      }
      Sys.sleep(3 * i)
    }
    stop("ArcGIS error for ", portid, ": ", res$error$message)
  }
  offset <- 0
  pages <- list()
  repeat {
    res <- fetch_page(offset)
    n <- NROW(res$features)
    if (n == 0) {
      break
    }
    pages[[length(pages) + 1]] <- res$features
    offset <- offset + n
    if (!isTRUE(res$exceededTransferLimit)) {
      break
    }
  }
  bind_rows(pages) |>
    rename_with(\(x) sub("^attributes\\.", "", x)) |>
    as_tibble()
}

# Load API keys from the git-ignored .env file. Blank keys count as absent.
if (file.exists(".env")) {
  dotenv::load_dot_env(".env")
}
api_key <- function(name) {
  key <- Sys.getenv(name)
  if (nzchar(key)) key else NULL
}
