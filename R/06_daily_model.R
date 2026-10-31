# Daily flows. Every producer-route-consumer triple keeps its monthly mean exactly.
# Scale factors interpolate between mid-month knots, with a break at the war start so
# pre-war days do not anticipate the shock. Hormuz flows follow the tanker signal.
source(file.path("R", "00_setup.R"))

flows <- read_csv(file.path(path_interim, "flows_monthly_model.csv"))
hormuz <- read_csv(file.path(path_interim, "hormuz_daily.csv"))
prices <- read_csv(file.path(path_interim, "prices_daily.csv"))

date_end <- min(max(hormuz$date[!hormuz$missing]), max(prices$date))
dates <- seq(date_start, date_end, by = "day")
day_month <- floor_date(dates, "month")
months <- sort(unique(day_month))
prewar <- dates < date_war

# Mid-month knots. The partial final month uses the middle of its available days.
mid_of <- function(m) {
  d <- dates[day_month == m]
  d[ceiling(length(d) / 2)]
}
month_mid <- as.Date(map_dbl(months, mid_of))

# 7-day tanker mean, floored at one vessel so a day of zero AIS calls cannot zero out
# a flow that other sources report. The floor only limits noise after the closure.
signal <- hormuz |>
  filter(date %in% dates) |>
  arrange(date) |>
  mutate(w = pmax(tanker_7d, 1)) |>
  pull(w)
signal <- signal / mean(signal[prewar])

scale_path <- function(s) {
  out <- numeric(length(dates))
  pre <- which(prewar)
  out[pre] <- approx(
    as.numeric(month_mid[1:2]), s[1:2],
    xout = as.numeric(dates[pre]), rule = 2
  )$y
  out
}

fit_daily <- function(targets, w, max_iter = 200, tol = 1e-5) {
  n <- length(months)
  s <- ifelse(targets > 0, targets, 0)
  v <- numeric(length(dates))
  war_i <- which(dates == date_war)
  ramp_end <- date_war + 7
  for (iter in seq_len(max_iter)) {
    v[prewar] <- (scale_path(s) * w)[prewar]
    left <- v[war_i - 1] / w[war_i]
    # Post-war knots: war start, one week later, then each month's middle.
    x <- as.numeric(c(date_war, ramp_end, month_mid[3:n]))
    y <- c(left, s[3], s[3:n])
    keep <- !duplicated(x)
    post <- which(!prewar)
    v[post] <- approx(x[keep], y[keep], xout = as.numeric(dates[post]), rule = 2)$y * w[post]
    means <- map_dbl(months, \(m) mean(v[day_month == m]))
    ok <- targets > 0 & means > 0
    if (all(abs(means[ok] / targets[ok] - 1) < tol)) {
      break
    }
    s[ok] <- s[ok] * (targets[ok] / means[ok])
    s[targets <= 0] <- 0
  }
  # Exact monthly means. Months with a zero target stay at zero.
  for (i in seq_len(n)) {
    idx <- day_month == months[i]
    m <- mean(v[idx])
    v[idx] <- if (targets[i] <= 0 || m <= 0) 0 else v[idx] * targets[i] / m
  }
  pmax(v, 0)
}

triples <- flows |>
  complete(nesting(producer, route, consumer), month = months, fill = list(mbd = 0)) |>
  arrange(producer, route, consumer, month)

daily <- triples |>
  group_by(producer, route, consumer) |>
  group_modify(\(d, key) {
    targets <- d$mbd[match(months, d$month)]
    w <- if (key$route == "hormuz") signal else rep(1, length(dates))
    tibble(date = dates, mbd = fit_daily(targets, w))
  }) |>
  ungroup()

write_csv(daily, file.path(path_interim, "flows_daily_model.csv"))
message("Daily flows: ", n_distinct(paste(daily$producer, daily$route, daily$consumer)), " triples, ", length(dates), " days to ", date_end)
