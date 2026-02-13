# ============================================================
# Household Container Water Capacity Analysis (Tidyverse)
# ============================================================
# Purpose:
# This script reads the current `container` sheet from the workbook,
# applies data-quality filters, calculates household total daily water
# liters, derives liters-per-person-per-day (L/P/D), and produces
# reusable outputs for reporting and QA.
#
# Core logic implemented:
# 1) Read `container` data.
# 2) Exclude rows where container volume > 1000 liters.
# 3) Exclude rows where `frequency_filled` is a pure numeric literal
#    that equals the same row's `volume_liters` (artifact pattern).
# 4) Compute row-level daily liters: volume_liters * fill_level * frequency_filled_num.
# 5) Aggregate row-level liters to household (`parent_index`).
# 6) Compute household L/P/D = total_daily_liters / household_size.
# 7) Keep subset with household total_daily_liters <= 100.
# 8) Output summary metrics, standards buckets, camp breakdown, and audit table.
#
# Notes:
# - This script uses the current `frequency_filled_num` as provided in
#   the workbook (after your latest corrections/reconciliation).
# - If `fill_level` is missing, it defaults to 1.
# - If `frequency_filled_num` is missing, it defaults to 1.
# ============================================================

# ------------------------------
# 1) Libraries
# ------------------------------
suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(stringr)
  library(janitor)
  library(readr)
  library(tibble)
})

# ------------------------------
# 2) User settings
# ------------------------------
input_file <- "data/20260210_wash_survey_hh_container_level_PROCESSED.xlsx"
input_sheet <- "container"

# Output folder for generated CSV files
output_dir <- "output"

# Prefix to keep outputs grouped together
output_prefix <- "container_lpd_artifact_filtered"

# ------------------------------
# 3) Helper functions
# ------------------------------

# Convert Arabic-Indic digits to ASCII digits, preserving text structure.
normalize_digits <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- NA_character_
  chartr("٠١٢٣٤٥٦٧٨٩", "0123456789", x)
}

# Return first mode (most common non-empty value) from a character vector.
first_mode <- function(x) {
  x <- as.character(x)
  x <- x[!is.na(x) & nzchar(x)]
  if (length(x) == 0) return(NA_character_)
  names(sort(table(x), decreasing = TRUE))[1]
}

# Humanitarian standards bucket for L/P/D.
lpd_bucket <- function(v) {
  if (is.na(v)) return(NA_character_)
  if (v < 7.5) return("Below Emergency Minimum (< 7.5 L/P/D)")
  if (v < 15)  return("Emergency Range (7.5-15 L/P/D)")
  if (v < 20)  return("Sphere Standard (15-20 L/P/D)")
  "Above WHO Minimum (>= 20 L/P/D)"
}

# ------------------------------
# 4) Read source data
# ------------------------------
# `clean_names()` standardizes names to snake_case for robust coding.
container_raw <- read_excel(input_file, sheet = input_sheet) |>
  clean_names()

# ------------------------------
# 5) Prepare analysis fields and exclusion flags
# ------------------------------
analysis_base <- container_raw |>
  mutate(
    # Core numeric fields
    vol_l = suppressWarnings(as.numeric(volume_liters)),
    fill = suppressWarnings(as.numeric(fill_level)),
    people = suppressWarnings(as.numeric(total_no_of_people_in_hh)),
    freq_num = suppressWarnings(as.numeric(frequency_filled_num)),

    # Frequency raw text normalized for artifact detection
    freq_raw_norm = normalize_digits(frequency_filled) |> str_squish(),
    freq_raw_is_pure_num = str_detect(freq_raw_norm, "^\\d+(?:\\.\\d+)?$"),
    freq_raw_num = suppressWarnings(as.numeric(freq_raw_norm)),

    # Artifact rule:
    # if raw frequency literal equals volume literal in same row,
    # treat row as corrupted frequency entry.
    freq_equals_volume =
      freq_raw_is_pure_num &
      !is.na(freq_raw_num) &
      !is.na(vol_l) &
      abs(freq_raw_num - vol_l) < 1e-9,

    # Outlier rule for container volume
    outlier_vol = !is.na(vol_l) & vol_l > 1000,

    # Combined exclusion rule
    exclude_row = outlier_vol | freq_equals_volume,

    # Analysis defaults
    fill = ifelse(is.na(fill), 1, pmin(pmax(fill, 0), 1)),
    freq_num = ifelse(is.na(freq_num), 1, pmax(freq_num, 0))
  )

# Keep only valid records for household calculations.
analysis_rows <- analysis_base |>
  filter(
    !exclude_row,
    !is.na(parent_index),
    !is.na(vol_l),
    vol_l > 0
  ) |>
  mutate(
    daily_liters_record = vol_l * fill * freq_num
  )

# ------------------------------
# 6) Aggregate to household level
# ------------------------------
hh <- analysis_rows |>
  group_by(parent_index) |>
  summarise(
    total_daily_liters = sum(daily_liters_record, na.rm = TRUE),
    household_size = suppressWarnings(max(people, na.rm = TRUE)),
    camp = first_mode(camp_name),
    .groups = "drop"
  ) |>
  mutate(
    household_size = ifelse(is.finite(household_size) & household_size > 0, household_size, NA_real_),
    lpd = total_daily_liters / household_size
  )

# All households with finite totals.
hh_all <- hh |>
  filter(is.finite(total_daily_liters))

# Requested analysis subset: households with <= 100 L/day total.
hh_le100 <- hh |>
  filter(total_daily_liters <= 100, is.finite(lpd))

# ------------------------------
# 7) Build summary outputs
# ------------------------------

# Main summary metrics.
summary_metrics <- tibble(
  metric = c(
    "Total Households Analyzed",
    "Households with total <= 100 L/day",
    "Households with total > 100 L/day",
    "Mean L/P/D (subset <=100)",
    "Median L/P/D (subset <=100)",
    "Standard Deviation (subset <=100)",
    "Minimum L/P/D (subset <=100)",
    "Maximum L/P/D (subset <=100)",
    "10th Percentile (subset <=100)",
    "25th Percentile Q1 (subset <=100)",
    "50th Percentile Median (subset <=100)",
    "75th Percentile Q3 (subset <=100)",
    "90th Percentile (subset <=100)",
    "95th Percentile (subset <=100)"
  ),
  value = c(
    nrow(hh_all),
    nrow(hh_le100),
    nrow(hh_all) - nrow(hh_le100),
    mean(hh_le100$lpd, na.rm = TRUE),
    median(hh_le100$lpd, na.rm = TRUE),
    sd(hh_le100$lpd, na.rm = TRUE),
    min(hh_le100$lpd, na.rm = TRUE),
    max(hh_le100$lpd, na.rm = TRUE),
    as.numeric(quantile(hh_le100$lpd, 0.10, na.rm = TRUE)),
    as.numeric(quantile(hh_le100$lpd, 0.25, na.rm = TRUE)),
    as.numeric(quantile(hh_le100$lpd, 0.50, na.rm = TRUE)),
    as.numeric(quantile(hh_le100$lpd, 0.75, na.rm = TRUE)),
    as.numeric(quantile(hh_le100$lpd, 0.90, na.rm = TRUE)),
    as.numeric(quantile(hh_le100$lpd, 0.95, na.rm = TRUE))
  )
)

# Humanitarian standards distribution (subset <= 100).
std_levels <- c(
  "Below Emergency Minimum (< 7.5 L/P/D)",
  "Emergency Range (7.5-15 L/P/D)",
  "Sphere Standard (15-20 L/P/D)",
  "Above WHO Minimum (>= 20 L/P/D)"
)

standards_breakdown <- hh_le100 |>
  mutate(level = vapply(lpd, lpd_bucket, character(1))) |>
  count(level, name = "households") |>
  right_join(tibble(level = std_levels), by = "level") |>
  mutate(
    households = ifelse(is.na(households), 0L, households),
    percentage = ifelse(sum(households) > 0, 100 * households / sum(households), 0)
  ) |>
  select(level, households, percentage)

# Camp-level L/P/D stats (subset <= 100).
camp_order <- c("Camp A", "Camp B", "Camp C", "Camp D")

camp_breakdown <- hh_le100 |>
  group_by(camp) |>
  summarise(
    households = n(),
    mean_lpd = mean(lpd, na.rm = TRUE),
    median_lpd = median(lpd, na.rm = TRUE),
    std_dev = sd(lpd, na.rm = TRUE),
    .groups = "drop"
  ) |>
  right_join(tibble(camp = camp_order), by = "camp") |>
  mutate(
    households = ifelse(is.na(households), 0L, households),
    mean_lpd = ifelse(is.na(mean_lpd), 0, mean_lpd),
    median_lpd = ifelse(is.na(median_lpd), 0, median_lpd),
    std_dev = ifelse(is.na(std_dev), 0, std_dev)
  )

# Audit table documenting exactly what was excluded.
analysis_audit <- tibble(
  metric = c(
    "rows_total_container",
    "rows_excluded_volume_gt_1000",
    "rows_excluded_freq_equals_volume",
    "rows_excluded_total",
    "rows_used_in_analysis",
    "households_total",
    "households_<=100",
    "mean_lpd_<=100",
    "median_lpd_<=100"
  ),
  value = c(
    nrow(analysis_base),
    sum(analysis_base$outlier_vol, na.rm = TRUE),
    sum(analysis_base$freq_equals_volume, na.rm = TRUE),
    sum(analysis_base$exclude_row, na.rm = TRUE),
    nrow(analysis_rows),
    nrow(hh_all),
    nrow(hh_le100),
    mean(hh_le100$lpd, na.rm = TRUE),
    median(hh_le100$lpd, na.rm = TRUE)
  )
)

# Optional detail table of excluded rows for QA.
excluded_rows <- analysis_base |>
  filter(exclude_row) |>
  transmute(
    index,
    parent_index,
    camp_name,
    volume_liters,
    frequency_filled,
    frequency_filled_num,
    outlier_vol,
    freq_equals_volume,
    exclusion_reason = case_when(
      outlier_vol & freq_equals_volume ~ "volume_gt_1000 + freq_equals_volume",
      outlier_vol ~ "volume_gt_1000",
      freq_equals_volume ~ "freq_equals_volume",
      TRUE ~ "other"
    )
  )

# ------------------------------
# 8) Write outputs
# ------------------------------
write_csv(hh, file.path(output_dir, paste0(output_prefix, "_household_all.csv")))
write_csv(hh_le100, file.path(output_dir, paste0(output_prefix, "_household_subset_le100.csv")))
write_csv(summary_metrics, file.path(output_dir, paste0(output_prefix, "_summary_metrics.csv")))
write_csv(standards_breakdown, file.path(output_dir, paste0(output_prefix, "_standards_breakdown.csv")))
write_csv(camp_breakdown, file.path(output_dir, paste0(output_prefix, "_camp_breakdown.csv")))
write_csv(analysis_audit, file.path(output_dir, paste0(output_prefix, "_audit.csv")))
write_csv(excluded_rows, file.path(output_dir, paste0(output_prefix, "_excluded_rows.csv")))

# ------------------------------
# 9) Console summary
# ------------------------------
cat("\n=== Household L/P/D Summary (Artifact-Filtered) ===\n")
cat("Input file: ", input_file, "\n", sep = "")
cat("Rows total (container): ", nrow(analysis_base), "\n", sep = "")
cat("Rows excluded (vol > 1000): ", sum(analysis_base$outlier_vol, na.rm = TRUE), "\n", sep = "")
cat("Rows excluded (freq equals volume): ", sum(analysis_base$freq_equals_volume, na.rm = TRUE), "\n", sep = "")
cat("Rows used: ", nrow(analysis_rows), "\n", sep = "")
cat("Households total: ", nrow(hh_all), "\n", sep = "")
cat("Households <=100 L/day: ", nrow(hh_le100), "\n", sep = "")
cat(sprintf("Mean L/P/D (<=100 subset): %.6f\n", mean(hh_le100$lpd, na.rm = TRUE)))
cat(sprintf("Median L/P/D (<=100 subset): %.6f\n", median(hh_le100$lpd, na.rm = TRUE)))

cat("\nOutputs written to: ", output_dir, "\n", sep = "")
cat("Prefix: ", output_prefix, "\n", sep = "")
