# Kobo Data Retrieval - KoboconnectR Approach
# Purpose: Download WASH survey data from KoboToolbox (household-level only)
# Date: 2026-02-05
#
# Output: Household-level dataset (~371 rows)
# - English column labels (via lang = "English (en)")
# - Multiple_select summary columns + boolean indicators (via multi_sel = "both")
# - Container repeat groups NOT expanded (will be implemented separately)
#
# Approach: Use KoboconnectR package wrapper for simplified data retrieval

# Libraries -----
library(tidyverse)
library(httr)
library(yaml)
library(here)
library(readxl)
library(writexl)
library(glue)
library(janitor)

# Configuration -----
kobo_config_path <- here("config.yaml")
mapping_file_path <- here("data", "Kobo version_02-Feb-2026.xlsx")

config <- read_yaml(kobo_config_path)

# Download household-level data using Kobo Export API -----
# Step 1: Create export task
export_url <- glue("https://{config$kobo$url}/api/v2/assets/{config$kobo$asset_id}/exports/")

export_response <- POST(
  export_url,
  authenticate(config$kobo$user, config$kobo$password, type = "basic"),
  body = list(
    type = "xls",
    lang = "English (en)",
    fields_from_all_versions = FALSE,
    hierarchy_in_labels = FALSE,
    group_sep = "/",
    multiple_select = "both",
    include_media_url = FALSE
  ),
  encode = "json",
  timeout(120)
)

stop_for_status(export_response, task = "create export")

export_data <- content(export_response)
export_uid <- export_data$uid
message(glue("Export task created: {export_uid}"))

# Step 2: Wait for export to complete and get download URL
max_attempts <- 30
attempt <- 1
export_ready <- FALSE

while (attempt <= max_attempts && !export_ready) {
  Sys.sleep(2)

  status_url <- glue("https://{config$kobo$url}/api/v2/assets/{config$kobo$asset_id}/exports/{export_uid}/")
  status_response <- GET(
    status_url,
    authenticate(config$kobo$user, config$kobo$password, type = "basic")
  )

  status_data <- content(status_response)

  if (!is.null(status_data$result)) {
    download_url <- status_data$result
    export_ready <- TRUE
    message("Export ready for download")
  } else {
    attempt <- attempt + 1
  }
}

if (!export_ready) {
  stop("Export did not complete within expected time")
}

# Step 3: Download the file
temp_file <- tempfile(fileext = ".xlsx")
download_response <- GET(
  download_url,
  authenticate(config$kobo$user, config$kobo$password, type = "basic"),
  write_disk(temp_file, overwrite = TRUE),
  timeout(120)
)

stop_for_status(download_response, task = "download export file")

# Step 4: Read the Excel file
wash_data <- read_excel(temp_file)
message(glue("Downloaded {nrow(wash_data)} household-level submissions"))

# Clean up temp file
unlink(temp_file)

# Clean column names to lowercase with underscores -----
names(wash_data) <- make_clean_names(names(wash_data))

# Load survey definitions for value mapping -----
choices_def <- read_excel(mapping_file_path, sheet = "choices")

# Apply value mapping for select_one questions (safety fallback) -----
mapping <- setNames(
  choices_def[["label::English (en)"]],
  choices_def[["name"]]
)

wash_data <- wash_data %>%
  mutate(across(where(is.character), ~ coalesce(mapping[.x], .x)))

# Fix multiple_select summary column separators (space → semicolon) -----
# The Kobo API uses space to separate multiple selected options in summary columns.
# Since option labels themselves contain spaces (e.g., "Public tap"), we need to
# intelligently replace only the spaces BETWEEN options, not within option labels.
#
# Strategy: Replace spaces that are followed by a capital letter (start of next option)
# Example: "Public tap Water truck" → "Public tap; Water truck"

# Identify multiple_select summary columns by finding columns with boolean indicators
all_cols <- names(wash_data)

summary_cols <- all_cols %>%
  keep(~ {
    # If column X has boolean columns named X_something, then X is a summary column
    potential_bool_pattern <- paste0("^", .x, "_")
    has_bool_indicators <- any(str_detect(all_cols, potential_bool_pattern))
    has_bool_indicators && is.character(wash_data[[.x]])
  })

message(glue("Found {length(summary_cols)} multiple_select summary columns to process"))

# Replace space separator with semicolon in summary columns
if (length(summary_cols) > 0) {
  wash_data <- wash_data %>%
    mutate(across(all_of(summary_cols), ~ {
      # Pattern: (?<=\w) = preceded by word character
      #          (?=[A-Z]) = followed by capital letter (start of next option)
      # This replaces "far Waterpoints" → "far; Waterpoints"
      # but keeps "Public tap" unchanged
      str_replace_all(.x, "(?<=\\w) (?=[A-Z])", "; ")
    }))
}

# Clean string values (remove control characters, prevent Excel issues) -----
wash_data <- wash_data %>%
  mutate(across(where(is.character), ~ {
    cleaned <- str_replace_all(.x, "[\\x00-\\x1f]", "")
    str_trunc(cleaned, width = 32000, ellipsis = "...")
  }))

# Data cleaning and filtering -----

# Columns to remove: Kobo metadata and survey administration fields
cols_to_remove <- c(
  # Organization-specific columns
  "international_rescue_committee_irc",
  "triangle_generation_humanitaire_tgh",
  "save_the_children_sci",
  "solidarites_international_si",
  # Survey administration
  "hello_my_name_is_xxx_and_i_work_with_org_name_i_would_like_to_ask_you_a_few_questions_to_better_understand_the_water_sanitation_and_hygiene_situation_in_your_location_the_survey_takes_around_10_15_minutes_you_can_stop_at_any_time_or_skip_questions_if_you_want_there_s_no_compensation_for_this_survey_and_your_responses_will_not_affect_any_future_assistance_this_survey_is_not_a_registration_survey_do_you_have_any_questions",
  "do_you_consent_to_be_interviewed",
  "thank_you_for_your_time_we_will_not_continue_with_the_survey",
  # GPS coordinates (individual components - redundant with geolocation)
  "gps_coordinates",
  "gps_coordinates_latitude",
  "gps_coordinates_longitude",
  "gps_coordinates_altitude",
  "gps_coordinates_precision"
)

# Move index to beginning, then remove columns 2-3 and metadata from 'id' onwards
wash_data <- wash_data %>%
  relocate(index) %>%
  # Remove columns 2-3 (former positions 1-2 before index moved)
  select(-c(2, 3))

# Find where 'id' column starts (metadata begins here) - after previous removals
id_position <- which(names(wash_data) == "id")

wash_data <- wash_data %>%
  # Remove all columns from 'id' onwards (all consecutive metadata at end)
  {if (length(id_position) > 0 && id_position > 0) select(., 1:(id_position - 1)) else .} %>%
  # Filter out non-consented interviews (before removing consent column)
  filter(!str_starts(do_you_consent_to_be_interviewed, "No")) %>%
  # Remove survey administration columns
  select(-any_of(cols_to_remove)) %>%
  # Create unified household head gender variable
  mutate(
    gender_of_the_househld = case_when(
      str_starts(is_the_responder_head_of_the_household, "Yes") ~ gender_of_the_respondent,
      str_starts(is_the_responder_head_of_the_household, "No") ~ specify_the_gender_of_the_househld,
      TRUE ~ NA_character_
    ),
    .after = specify_the_gender_of_the_househld
  ) %>%
  # Move index to the beginning
  relocate(index)

message(glue("After filtering: {nrow(wash_data)} consented households"))

# ---- Extract Arabic Content Columns ----
# Purpose: Separate Arabic free-text responses for translation/review
# Columns: if_other*, if_others*, comments*, hh_fc_7_1_is_there_anything_else*
# Output: output/wash_survey_arabic_content.xlsx

# Pre-flight validation
if (!"index" %in% names(wash_data)) {
  stop("Expected 'index' column not found in wash_data. Data structure may have changed.")
}

message("\nExtracting Arabic content columns...")
message(glue("   Source dataset: {nrow(wash_data)} rows × {ncol(wash_data)} columns"))

# Identify Arabic content columns by pattern matching
arabic_patterns <- c(
  "^if_other",
  "^if_others",
  "^comments",
  "^hh_fc_7_1_is_there_anything_else"
)

arabic_cols <- names(wash_data) %>%
  keep(~ str_detect(.x, paste(arabic_patterns, collapse = "|")))

message(glue("   Found {length(arabic_cols)} Arabic content columns"))

# Conditional execution: only proceed if Arabic columns found
if (length(arabic_cols) == 0) {
  warning("No Arabic content columns found matching patterns: ",
          paste(arabic_patterns, collapse = ", "))
  message("   Skipping Arabic content extraction\n")
} else {

  # Verify column name uniqueness (defensive check)
  if (any(duplicated(arabic_cols))) {
    duplicated_names <- arabic_cols[duplicated(arabic_cols)]
    warning(glue("Duplicate column names detected: {paste(duplicated_names, collapse = ', ')}"))
  }

  # Create Arabic content dataframe
  arabic_content <- wash_data %>%
    select(index, all_of(arabic_cols)) %>%
    # Sort columns: index first, then alphabetical for consistency
    select(index, sort(tidyselect::peek_vars()[-1])) %>%
    # Filter: keep only rows with at least one non-empty Arabic field
    filter(if_any(-index, ~ !is.na(.x) & .x != ""))

  # Calculate statistics
  message(glue("   Extracted: {nrow(arabic_content)} rows with non-empty Arabic content"))

  # Export with error handling
  output_file <- here("output", "wash_survey_arabic_content.xlsx")


  write_xlsx(
    arabic_content,
    path = output_file,
    format_headers = TRUE
  )
  message(glue("   Saved: {basename(output_file)}"))
  message(glue("   Dimensions: {nrow(arabic_content)} rows × {ncol(arabic_content)} columns (index + {ncol(arabic_content) - 1} Arabic fields)\n"))
  
}

# ---- Save Main Outputs ----
output_dir <- here("output")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

write_xlsx(wash_data, here("output", "wash_survey_hh_level.xlsx"))
saveRDS(wash_data, here("output", "wash_survey_hh_level.rds"))

message(glue("
Household-level: {nrow(wash_data)} rows x {ncol(wash_data)} columns
Output saved to: {output_dir}
"))
