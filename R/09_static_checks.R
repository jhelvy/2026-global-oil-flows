# Static versions of the graphic, made before the D3 version. If these look right, the data
# and the story are right, and the animated graphic only has to bring them to life.
#   1. Brent price line chart
#   2. Sankey of daily flows just before the war (early January)
#   3. Sankey of daily flows shortly after the strait closed (mid-March)
# Writes PNGs to figs/static/. Not part of run_all.R, because the site does not need them.
source(file.path("R", "00_setup.R"))
library(cowplot)
library(ggrepel)

font <- "Roboto Condensed"
col_hormuz <- "#980000"
col_bypass <- "#E37D39"
col_other <- "grey75"

path_static <- file.path("figs", "static")
dir.create(path_static, recursive = TRUE, showWarnings = FALSE)

date_before <- as.Date("2026-01-05")
date_after <- as.Date("2026-03-15")

flows <- read_csv(file.path(path_final, "flows_daily.csv"))
prices <- read_csv(file.path(path_interim, "prices_daily.csv"))

theme_static <- function(...) {
  theme_minimal_grid(font_family = font, ...) +
    theme(
      plot.title.position = "plot",
      plot.caption.position = "plot",
      plot.caption = element_text(hjust = 0, face = "italic"),
      panel.background = element_rect(fill = "white", color = NA),
      plot.background = element_rect(fill = "white", color = NA)
    )
}

# 1. Brent price ----

brent <- prices |>
  filter(date >= date_start, date <= date_stop)

price_plot <- brent |>
  ggplot(aes(x = date, y = brent)) +
  geom_vline(xintercept = date_war, linetype = "dashed", color = "grey50") +
  geom_line(color = col_hormuz, linewidth = 0.9) +
  geom_point(
    data = brent |> filter(date %in% c(date_before, date_after)),
    size = 3,
    color = col_hormuz
  ) +
  geom_text_repel(
    data = brent |> filter(date %in% c(date_before, date_after)),
    aes(label = paste0("$", round(brent))),
    nudge_x = c(0, -9),
    nudge_y = 8,
    segment.color = NA,
    family = font
  ) +
  annotate(
    "text",
    x = date_war,
    y = max(brent$brent),
    label = "War starts, Feb 28 ",
    hjust = 1,
    family = font,
    color = "grey30"
  ) +
  scale_x_date(date_breaks = "1 month", date_labels = "%b") +
  scale_y_continuous(labels = scales::label_dollar()) +
  labs(
    x = NULL,
    y = "Brent crude, $ per barrel",
    title = "Oil prices jumped when the Strait of Hormuz closed",
    caption = "Data source: FRED / EIA daily Brent spot price"
  ) +
  theme_static()

ggsave(
  file.path(path_static, "brent-price.png"),
  price_plot,
  width = 8,
  height = 5,
  dpi = 300
)

# 2 & 3. Static Sankeys ----

# One fixed top-to-bottom order for every node, so the two dates line up.
order_source <- c(
  "Saudi Arabia", "Iraq", "UAE", "Kuwait", "Iran", "Other Gulf", "Rest of World",
  "Brazil", "USA", "Canada", "Russia", "Gulf storage", "Cargoes at sea", "Stock draws"
)
order_route <- c(
  "Strait of Hormuz", "Gulf bypass pipelines", "Other seaborne",
  "Cross-border pipelines", "Domestic (no transit)"
)
order_target <- c(
  "China", "India", "Japan", "South Korea", "Other Asia", "Europe (EU + UK)",
  "Middle East", "Rest of World", "USA", "Cargoes at sea", "Stock builds"
)

# Total height used by the tallest column on either date, plus gaps. Fixing it keeps the
# two Sankeys on the same scale, so a band's thickness means the same thing in both.
gap <- 2.4
y_max <- flows |>
  filter(date %in% c(date_before, date_after)) |>
  summarise(total = sum(value), .by = c(date, source)) |>
  summarise(total = sum(total) + gap * length(order_source), .by = date) |>
  pull(total) |>
  max()

# Place the nodes of one column: stack them in order, centered on the shared height.
layout_nodes <- function(totals, node_order, x) {
  tibble(node = node_order) |>
    left_join(totals, by = join_by(node)) |>
    mutate(
      total = replace_na(total, 0),
      height = total,
      offset = cumsum(lag(height + gap, default = 0)),
      ymin = offset + (y_max - (sum(height) + gap * (n() - 1))) / 2,
      ymax = ymin + height,
      x = x
    ) |>
    select(node, x, ymin, ymax, total)
}

# Give each link its slot on both ends: a node's bands are ordered by where they go.
layout_links <- function(links, from_nodes, to_nodes, from_order, to_order) {
  links |>
    arrange(match(to, to_order)) |>
    mutate(from_start = cumsum(value) - value, .by = from) |>
    arrange(match(from, from_order)) |>
    mutate(to_start = cumsum(value) - value, .by = to) |>
    left_join(
      from_nodes |> select(from = node, x_from = x, y_from = ymin),
      by = join_by(from)
    ) |>
    left_join(
      to_nodes |> select(to = node, x_to = x, y_to = ymin),
      by = join_by(to)
    ) |>
    mutate(
      y0 = y_from + from_start,
      y1 = y_to + to_start
    )
}

# A band is a ribbon that eases from its start slot to its end slot.
band_curve <- function(links, n = 40) {
  links |>
    mutate(link_id = row_number()) |>
    reframe(
      t = seq(0, 1, length.out = n),
      x = x_from + (x_to - x_from) * t,
      ease = 3 * t^2 - 2 * t^3,
      ymin = y0 + (y1 - y0) * ease,
      ymax = ymin + value,
      .by = c(link_id, route_color)
    )
}

make_sankey <- function(day, title) {
  d <- flows |> filter(date == day, value > 0)

  source_totals <- d |> summarise(total = sum(value), .by = source) |> rename(node = source)
  route_totals <- d |> summarise(total = sum(value), .by = route) |> rename(node = route)
  target_totals <- d |> summarise(total = sum(value), .by = target) |> rename(node = target)

  nodes_source <- layout_nodes(source_totals, order_source, 0)
  nodes_route <- layout_nodes(route_totals, order_route, 1)
  nodes_target <- layout_nodes(target_totals, order_target, 2)

  link_color <- \(route) case_when(
    route == "Strait of Hormuz" ~ col_hormuz,
    route == "Gulf bypass pipelines" ~ col_bypass,
    .default = col_other
  )

  left <- d |>
    summarise(value = sum(value), .by = c(source, route)) |>
    rename(from = source, to = route) |>
    layout_links(nodes_source, nodes_route, order_source, order_route) |>
    mutate(route_color = link_color(to))
  right <- d |>
    summarise(value = sum(value), .by = c(route, target)) |>
    rename(from = route, to = target) |>
    layout_links(nodes_route, nodes_target, order_route, order_target) |>
    mutate(route_color = link_color(from))

  # Shrink the node bars to a sliver so the bands, not the bars, carry the eye.
  half_width <- 0.012
  nodes <- bind_rows(nodes_source, nodes_route, nodes_target) |> filter(total > 0)
  bands <- bind_rows(left, right) |>
    mutate(
      x_from = x_from + half_width,
      x_to = x_to - half_width
    ) |>
    band_curve()

  labels <- nodes |>
    filter(total >= 0.5) |>
    mutate(
      y = (ymin + ymax) / 2,
      label = paste0(node, "  ", round(total, 1)),
      hjust = case_when(x == 0 ~ 1, x == 2 ~ 0, .default = 0.5),
      x_label = case_when(x == 0 ~ x - 0.02, x == 2 ~ x + 0.02, .default = x)
    )

  ggplot() +
    geom_ribbon(
      data = bands,
      aes(x = x, ymin = ymin, ymax = ymax, group = link_id, fill = route_color),
      alpha = 0.6
    ) +
    geom_rect(
      data = nodes,
      aes(xmin = x - half_width, xmax = x + half_width, ymin = ymin, ymax = ymax),
      fill = "grey25"
    ) +
    geom_text(
      data = labels |> filter(x != 1),
      aes(x = x_label, y = y, label = label, hjust = hjust),
      family = font,
      size = 5
    ) +
    geom_label(
      data = labels |> filter(x == 1),
      aes(x = x_label, y = y, label = label),
      family = font,
      size = 5,
      linewidth = 0,
      fill = alpha("white", 0.85)
    ) +
    scale_fill_identity() +
    scale_x_continuous(expand = expansion(mult = c(0.36, 0.36))) +
    scale_y_reverse() +
    labs(
      title = title,
      subtitle = paste0(
        format(day, "%B "), as.integer(format(day, "%d")), format(day, ", %Y"),
        ". Crude oil flows in million barrels per day: producer, route, consumer."
      ),
      caption = "Modeled estimates, not measurements. Data: data/final/flows_daily.csv"
    ) +
    theme_void(base_family = font) +
    theme(
      plot.title = element_text(face = "bold", size = 20),
      plot.subtitle = element_text(size = 14),
      plot.title.position = "plot",
      plot.caption.position = "plot",
      plot.caption = element_text(hjust = 0, face = "italic"),
      plot.margin = margin(10, 10, 10, 10),
      plot.background = element_rect(fill = "white", color = NA)
    )
}

sankey_before <- make_sankey(date_before, "Before the war: about 15 million barrels a day pass through Hormuz")
sankey_after <- make_sankey(date_after, "After the closure: less than 1 million barrels a day get through")

ggsave(
  file.path(path_static, "sankey-before.png"),
  sankey_before,
  width = 10,
  height = 7,
  dpi = 200
)
ggsave(
  file.path(path_static, "sankey-after.png"),
  sankey_after,
  width = 10,
  height = 7,
  dpi = 200
)

# The numbers behind the titles, so the titles can be checked against the data.
flows |>
  filter(date %in% c(date_before, date_after)) |>
  summarise(
    total = sum(value),
    hormuz = sum(value[route == "Strait of Hormuz"]),
    hormuz_share = hormuz / total,
    .by = date
  ) |>
  print()
