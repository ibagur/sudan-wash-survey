# Extract Boolean Column Patterns from Household Data
# Purpose: Generate complete lists of boolean columns for indicators guide
# Date: 2026-02-10

library(tidyverse)
library(here)

# Load household data
hh_data <- readRDS(here("output", "wash_survey_hh_level.rds"))

# Get all column names
all_cols <- names(hh_data)

# Define patterns for multiple-select questions (base prefixes)
multiselect_patterns <- tribble(
  ~indicator, ~base_pattern, ~description,
  "1.3", "if_yes_follow_with_the_list", "Water access problems",
  "1.4", "hh_ws_1_2_2_if_applicable_how_does_your_household_adapt_to_lack_of_water", "Water coping mechanisms",
  "1.6", "hh_ws_1_2_3_how_long_does_it_take_to_go_to_your_main_water_source_fetch_water_and_return_including_queuing_at_the_water_source", "Time to fetch water",
  "2.1", "hh_s_2_1_what_kind_of_sanitation_facility_latrine_toilet_does_your_household_usually_use", "Sanitation facility type",
  "2.3", "hh_s_2_1_2_do_you_have_problems_related_to_sanitation_facilities_latrines_toilets_if_yes_which_ones", "Sanitation problems",
  "2.4", "hh_s_2_1_3_if_applicable_how_do_you_adapt_to_issues_related_to_sanitation_facilities_latrines_toilets", "Sanitation coping",
  "2.6a", "hh_s_2_6_1_if_yes_which_groups_are_practicing_open_defecation", "Open defecation - who",
  "2.6b", "hh_s_2_6_1_1_if_yes_when_is_open_defecation_most_often_observed", "Open defecation - when",
  "2.7", "hh_s_2_2_where_do_children_under_5_who_are_living_in_this_household_usually_go_to_defecate", "Children <5 defecation",
  "3.0", "hh_swm_3_1_what_is_the_most_common_way_your_household_disposes_of_garbage", "Solid waste disposal",
  "4.1", "hh_h_4_1_does_your_household_have_problems_related_to_hygiene_items_soap_feminine_hygiene_products_baby_diapers_toothpaste_brush_if_yes_which_ones", "Hygiene NFI problems",
  "4.2", "hh_h_4_1_1_if_applicable_how_does_your_household_adapt_to_issues_related_to_hygiene_items", "Hygiene coping",
  "4.7.2", "hh_h_4_3_1_if_applicable_please_tell_me_the_main_reason_why_your_household_does_not_have_soap", "Soap access problems"
)

# Function to extract matching columns
extract_boolean_cols <- function(pattern) {
  matching <- all_cols[str_starts(all_cols, fixed(pattern))]

  # For most patterns, the boolean columns have an underscore suffix
  # The parent question itself doesn't have the suffix pattern
  # Filter to only those with additional suffix (the boolean columns)
  boolean_cols <- matching[nchar(matching) > nchar(pattern)]

  return(boolean_cols)
}

# Extract all boolean column sets
results <- multiselect_patterns %>%
  mutate(
    boolean_cols = map(base_pattern, extract_boolean_cols),
    n_booleans = map_int(boolean_cols, length)
  )

# Create formatted output for guide
output_lines <- c(
  "# Boolean Column Reference for Indicators Guide",
  "# Generated: 2026-02-10",
  "# Source: output/wash_survey_hh_level.rds",
  "",
  "This document lists all boolean columns for multiple-select indicators.",
  "Format: One boolean column per choice option, named `{base}_{choice_label}`",
  ""
)

for (i in 1:nrow(results)) {
  output_lines <- c(
    output_lines,
    paste0("## ", results$indicator[i], ": ", results$description[i]),
    paste0("**Base pattern:** `", results$base_pattern[i], "`"),
    paste0("**Number of boolean columns:** ", results$n_booleans[i]),
    "",
    "**Boolean columns:**"
  )

  boolean_list <- results$boolean_cols[[i]]
  if (length(boolean_list) > 0) {
    for (col in boolean_list) {
      output_lines <- c(output_lines, paste0("- `", col, "`"))
    }
  } else {
    output_lines <- c(output_lines, "*No boolean columns found - may be single-select question*")
  }

  output_lines <- c(output_lines, "")
}

# Save to file
writeLines(output_lines, here("reference", "boolean_columns_reference.md"))

# Print summary
cat("\nBoolean Column Extraction Summary\n")
cat("==================================\n\n")
for (i in 1:nrow(results)) {
  cat(sprintf("%-6s %-40s %2d booleans\n",
              results$indicator[i],
              str_trunc(results$description[i], 40),
              results$n_booleans[i]))
}
cat("\nOutput saved to: reference/boolean_columns_reference.md\n")
