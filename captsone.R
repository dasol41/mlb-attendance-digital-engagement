###############################################################################
# SOFTWARE APPENDIX: MLB Attendance & Google Trends Analysis Script
# Author: Dasol Shin
# Description:
#   This script processes MLB game logs and Google Trends data (2023–2025),
#   constructs a weekly NL East team-week panel, and estimates a two-way
#   fixed-effects regression to evaluate whether online search interest
#   predicts next-week attendance.
###############################################################################

# ----------------------------------------------------------------------
# SECTION 1: LIBRARIES & ENVIRONMENT SETUP
# ----------------------------------------------------------------------
library(tidyverse)
library(lubridate)
library(plm)
library(lmtest)
library(readr)
library(janitor)
library(stargazer)
library(ggplot2)
library(zoo)

# ----------------------------------------------------------------------
# SECTION 2: GOOGLE TRENDS DATA PROCESSING (WIDE → LONG)
# ----------------------------------------------------------------------

files_trend <- c("2023 google trend.csv",
                 "2024 google trend.csv",
                 "2025 google trend.csv")

trend_raw <- purrr::map_dfr(files_trend, function(file) {
  read_csv(file, col_types = cols()) %>%
    clean_names() %>%
    mutate(
      date = as.Date(date),
      across(-date, ~ suppressWarnings(as.numeric(.)))
    )
})

trend_long <- trend_raw %>%
  pivot_longer(
    cols = -date,
    names_to = "team_raw",
    values_to = "google_trend_daily"
  )

team_lookup <- c(
  "washington nationals" = "Washington Nationals",
  "philadelphia phillies" = "Philadelphia Phillies",
  "new york mets" = "New York Mets",
  "atlanta braves" = "Atlanta Braves",
  "miami marlins" = "Miami Marlins"
)

trend_data_final <- trend_long %>%
  mutate(
    team_clean = str_replace_all(team_raw, "_", " ") |> tolower(),
    team = recode(team_clean, !!!team_lookup),
    week_start = date + 1
  ) %>%
  group_by(team, week_start) %>%
  summarise(avg_google_trend = mean(google_trend_daily, na.rm = TRUE),
            .groups = "drop")

# ----------------------------------------------------------------------
# SECTION 3: MLB ATTENDANCE & WIN RATE DATA PROCESSING
# ----------------------------------------------------------------------

files_mlb <- c(
  "2023-atlanta.csv", "2023-miami.csv", "2023-nymets.csv",
  "2023-phili.csv", "2023-nationals.csv",
  "2024-atlanta.csv", "2024-miami.csv", "2024-nymets.csv",
  "2024-phili.csv", "2024-nationals.csv",
  "2025-atlanta.csv", "2025-miami.csv", "2025-nymets.csv",
  "2025-phili.csv", "2025-nationals.csv"
)

team_name_mapping <- c(
  "ATL" = "Atlanta Braves",
  "MIA" = "Miami Marlins",
  "NYM" = "New York Mets",
  "PHI" = "Philadelphia Phillies",
  "WSN" = "Washington Nationals"
)

mlb_raw_data_list <- lapply(files_mlb, function(file) {
  year_extracted <- str_extract(file, "^[0-9]{4}")
  
  read_csv(file, skip = 31, col_names = TRUE) %>%
    select(gm = 1, date_string = 2, team_id = 3, wl = 4, dn = 5, attendance = 6) %>%
    mutate(
      full_date = paste(date_string, year_extracted),
      game_date = parse_date_time(full_date, "A b d Y"),
      attendance = as.numeric(str_replace_all(attendance, ",", "")),
      attendance = replace_na(attendance, 0),
      win = ifelse(str_starts(wl, "W"), 1, 0),
      team = recode(team_id, !!!team_name_mapping),
      is_home_game = 1L
    ) %>%
    select(team, game_date, is_home_game, attendance, win)
})

mlb_raw_data <- bind_rows(mlb_raw_data_list) %>%
  filter(!is.na(game_date))

mlb_weekly_data <- mlb_raw_data %>%
  mutate(week_start = floor_date(game_date, "week", week_start = 7)) %>%
  group_by(team, week_start) %>%
  summarise(
    weekly_attendance = sum(attendance),
    weekly_home_games = sum(is_home_game),
    weekly_wins = sum(win),
    weekly_games = n(),
    .groups = "drop"
  ) %>%
  arrange(team, week_start) %>%
  group_by(team) %>%
  mutate(
    cumulative_wins = cumsum(weekly_wins),
    cumulative_games_played = cumsum(weekly_games),
    win_rate_t_1 = lag(cumulative_wins / cumulative_games_played, 1)
  ) %>%
  ungroup() %>%
  filter(!is.na(win_rate_t_1))

# ----------------------------------------------------------------------
# SECTION 4: MERGE DATASETS + LOG TRANSFORMATION
# ----------------------------------------------------------------------

panel_data_final <- inner_join(
  mlb_weekly_data,
  trend_data_final,
  by = c("team", "week_start")
) %>%
  arrange(team, week_start) %>%
  mutate(
    ln_attendance_t = log(weekly_attendance + 1),
    ln_trend_t = log(avg_google_trend + 1)
  ) %>%
  group_by(team) %>%
  mutate(ln_trend_t_1 = lag(ln_trend_t, 1)) %>%
  ungroup() %>%
  filter(!is.na(ln_trend_t_1))

# ----------------------------------------------------------------------
# SECTION 5: TWO-WAY FIXED EFFECTS REGRESSION
# ----------------------------------------------------------------------

pdata <- pdata.frame(panel_data_final, index = c("team", "week_start"))

model_fe <- plm(
  ln_attendance_t ~ ln_trend_t_1 + win_rate_t_1 + weekly_home_games,
  data = pdata,
  model = "within",
  effect = "twoways"
)

model_summary <- coeftest(model_fe, vcov = vcovHC(model_fe, type = "HC1", cluster = "group"))
print(model_summary)

# ----------------------------------------------------------------------
# SECTION 6: VISUALIZATION
# ----------------------------------------------------------------------

# Time-series plot
plot_timeseries <- panel_data_final %>%
  select(team, week_start, ln_attendance_t, ln_trend_t_1) %>%
  pivot_longer(cols = c(ln_attendance_t, ln_trend_t_1),
               names_to = "variable", values_to = "value") %>%
  ggplot(aes(week_start, value, color = variable)) +
  geom_line(alpha = 0.8) +
  facet_wrap(~ team, scales = "free_y") +
  theme_minimal()

plot_timeseries

# Scatter plot with fitted line
plot_scatter <- panel_data_final %>%
  ggplot(aes(ln_trend_t_1, ln_attendance_t, color = team)) +
  geom_point(alpha = .6) +
  geom_smooth(method = "lm", color = "black", se = FALSE) +
  theme_minimal()

plot_scatter

# ----------------------------------------------------------------------
# SECTION 7: SUMMARY STATISTICS & LATEX TABLES
# ----------------------------------------------------------------------

summary_vars <- panel_data_final %>%
  select(
    weekly_attendance,
    avg_google_trend,
    win_rate_t_1,
    weekly_home_games,
    ln_attendance_t,
    ln_trend_t_1
  )

stargazer(
  summary_vars,
  type = "latex",
  summary.stat = c("n","mean","sd","min","max"),
  title = "Summary Statistics",
  out = "summary_statistics.tex"
)

stargazer(
  model_fe,
  type = "latex",
  title = "Two-Way Fixed Effects Regression: Log Attendance",
  dep.var.labels = "Log Weekly Attendance",
  covariate.labels = c("Lagged Log Google Trend (t-1)",
                       "Lagged Cumulative Win Rate (t-1)",
                       "Weekly Home Games"),
  out = "regression_results.tex",
  notes = "Cluster-robust SEs (Team level). Time & Team FE included.",
  add.lines = list(c("Team FE", "Yes"),
                   c("Time FE", "Yes"))
)

###############################################################################
# END OF SCRIPT
###############################################################################
